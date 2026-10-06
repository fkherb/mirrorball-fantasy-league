#!/usr/bin/env python3
"""Outbound-only Linux coordinator. Supabase owns schedules and pending couples.

--check verifies authentication. --once processes one claimed job.
--preview-week N --mode MODE gathers data without importing or uploading it.
With no options, poll every minute. Never run alongside another coordinator.
"""
import argparse
import concurrent.futures
import fcntl
import importlib.util
import json
import logging
import os
from pathlib import Path
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
LOG = logging.getLogger("dwts-worker")


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


class Worker:
    def __init__(self, config, state=None):
        self.url = config["SUPABASE_URL"].rstrip("/")
        self.secret = config["DWTS_AUTOMATION_WORKER_SECRET"]
        self.token = config.get("DWTS_PHOTOS_GITHUB_TOKEN", "")
        self.name = config.get("DWTS_WORKER_NAME") or socket.gethostname()
        if not self.url.startswith("https://") or len(self.secret) < 32:
            raise ValueError("Configure HTTPS SUPABASE_URL and a worker secret of at least 32 characters")
        self.state = state or ROOT / ".worker-state"
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.wiki = module("dwts_wiki", "dwts-wiki.py")
        self.photos = module("dwts_photos", "dwts-photos.py")

    def scrub(self, value):
        for secret in (self.secret, self.token):
            if secret:
                value = value.replace(secret, "[REDACTED]")
        return value

    def api(self, action, **kwargs):
        request = urllib.request.Request(self.url + "/functions/v1/dwts-automation-worker",
            data=json.dumps({"worker": self.name, "action": action, **kwargs}).encode(),
            headers={"Authorization": "Bearer " + self.secret, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            raise ApiError(exc.code, self.scrub(exc.read().decode()[:1000])) from None
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ApiError(503, self.scrub(str(exc))) from None

    def photo_result(self, task, preview=False):
        if not self.token:
            raise ValueError("DWTS_PHOTOS_GITHUB_TOKEN is missing")
        targets = task["targets"]
        if not preview:
            existing = self.photos.remote_files(task["folder"], self.token)
            verified = []
            for target in targets:
                prefix = re.escape(self.photos.couple_name(target))
                files = [{"path": task["folder"] + "/" + name} for name in existing
                    if re.fullmatch(prefix + r"-\d+\.(?:avif|jpg|jpeg|png|webp)", name, re.I)]
                if files:
                    verified.append({"dance_id": target["dance_id"], "files": files})
            if verified:
                head = self.photos.gh("GET", "/git/ref/heads/main", self.token)["object"]["sha"]
                for item in verified:
                    item["commit_sha"] = head
                response = self.api("reconcile", run_id=task["run_id"], verified=verified)
                done = set(response["verified_dance_ids"])
                targets = [t for t in targets if t["dance_id"] not in done]
        couples = [{"star_name": t["star_name"], "pro_name": t["pro_name"]} for t in targets]
        if not couples:
            return self.photos.new_result(task["week"], [], preview)
        state = {"downloaded": {p["post_id"]: {} for p in task.get("known_photo_posts", [])}}
        return self.photos.run(task["week"], couples, self.token, task.get("since"),
            dry_run=preview, external_state=state)

    def gather(self, task, preview=False):
        if task["mode"] == "photos":
            return self.photo_result(task, preview)
        if task["mode"] == "get-weeks":
            return self.wiki.fetch_information("get-weeks")
        couples = [{"star_name": t["star_name"], "pro_name": t["pro_name"]} for t in task["targets"]]
        return self.wiki.fetch_information(task["mode"], couples, task.get("week_tag"))

    def persist(self, run_id, result):
        destination = self.state / ("pending-" + run_id + ".json")
        temporary = destination.with_suffix(".tmp")
        data = self.scrub(json.dumps({"run_id": run_id, "result": result}))
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
        return destination

    def flush(self, path):
        data = json.loads(path.read_text())
        try:
            self.api("heartbeat", run_id=data["run_id"])
            summary = self.api("report", **data)
            LOG.info("Reported %s: %s", data["run_id"], self.scrub(json.dumps(summary)))
        except ApiError as exc:
            if exc.status != 409:
                raise
            LOG.warning("Discarding replaced run %s; next photo job rechecks GitHub", data["run_id"])
        path.unlink()

    def execute(self, task):
        stop = threading.Event()
        def renew():
            while not stop.wait(60):
                try:
                    self.api("heartbeat", run_id=task["run_id"])
                except ApiError as exc:
                    LOG.warning("Heartbeat: %s", exc)
        thread = threading.Thread(target=renew, daemon=True)
        thread.start()
        try:
            try:
                result = self.gather(task)
            except Exception as exc:
                result = {"error": self.scrub(str(exc)), "failed_run": True,
                    "week": task["week"], "dry_run": False, "errors": [{"message": self.scrub(str(exc))}]}
            path = self.persist(task["run_id"], result)
            self.flush(path)
        finally:
            stop.set()
            thread.join()

    def run(self, once=False):
        with (self.state / "worker.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("Another worker is running; stop the service before using --once") from None
            futures = set()
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                while True:
                    try:
                        # Replay durable results before claiming new work.
                        active = bool(futures)
                        if not active:
                            for path in sorted(self.state.glob("pending-*.json")):
                                self.flush(path)
                        for future in list(futures):
                            if future.done():
                                futures.remove(future)
                                future.result()
                        if len(futures) < 3:
                            task = self.api("claim")
                            if task.get("run_id"):
                                LOG.info("Starting Week %s %s", task["week"], task["mode"])
                                futures.add(pool.submit(self.execute, task))
                            else:
                                LOG.info("No due work")
                        if once:
                            for future in futures:
                                future.result()
                            return
                    except ApiError as exc:
                        LOG.warning("Will retry next minute: %s", exc)
                        if once:
                            raise
                    time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true")
    group.add_argument("--once", action="store_true")
    group.add_argument("--preview-week", type=int)
    parser.add_argument("--mode", choices=["get-weeks", "pre-show", "live-show", "post-show", "photos"])
    parser.add_argument("--week-tag")
    args = parser.parse_args()
    from dotenv import load_dotenv
    load_dotenv(ROOT / ".env")
    worker = Worker(os.environ)
    if args.check:
        print(json.dumps(worker.api("heartbeat"), indent=2))
    elif args.preview_week:
        if not args.mode:
            parser.error("--preview-week requires --mode")
        task = worker.api("preview", week=args.preview_week, mode=args.mode, week_tag=args.week_tag)
        print(worker.scrub(json.dumps(worker.gather(task, preview=True), indent=2)))
    else:
        worker.run(args.once)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        main()
    except (ApiError, ValueError) as exc:
        LOG.error("%s", exc)
        sys.exit(1)
