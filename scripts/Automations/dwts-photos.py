#!/usr/bin/env python3
"""Fetch DWTS couple photos and upload them to GitHub, returning only JSON.

Usage:
  python3 dwts-photos.py --week 3 --couples @couples.json --git-token YOUR_TOKEN --print
  python3 dwts-photos.py --week 3 --couples @couples.json --git-token YOUR_TOKEN --dry-run --print

--couples accepts the same inline JSON or @filename format as the wiki reader:
{"Amber Glenn": "Pasha Pashkov"}, or a list of star_name/pro_name objects.
Both FULL names must occur in a post caption, as in the original photo script.
remaining_couples can be fed directly back into --couples on the next run.
The token may be supplied through DWTS_PHOTOS_GITHUB_TOKEN in the adjacent .env.

Dry runs read the timeline, repository, and existing state, but do not download,
upload, or save state. Planned matches do not count as successful uploads.
Rate limits end the run immediately; skip_next_run is true only when a known
cooldown exceeds 300 seconds. Cooldown details appear only in rate-limit errors.
"""

import argparse
import base64
import importlib.util
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from email.utils import parsedate_to_datetime
from pathlib import Path


GITHUB_REPO = "fkherb/mirrorball-fantasy-league"
BRANCH = "main"
DANCES_DIR = "Images/Dances"
HANDLE = "officialdwts"
STATE = Path(os.environ.get("DWTS_STATE", "~/.dwts_photos_state.json")).expanduser()
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
RATE_MARKER = "DWTS_GALLERY_RATE_LIMIT:"


class PhotoError(ValueError):
    pass


class RateLimitError(PhotoError):
    def __init__(self, service, seconds=None):
        self.service = service
        self.seconds = seconds
        super().__init__(f"{service} rate limit reached; no automatic retry was made.")


def cooldown_seconds(headers, now=None):
    """Use server-supplied Retry-After (seconds/date) or reset timestamp."""
    now = time.time() if now is None else now
    headers = {str(k).lower(): v for k, v in headers.items()}
    delays = []
    retry = headers.get("retry-after")
    if retry is not None:
        try:
            delays.append(float(retry))
        except (TypeError, ValueError):
            try:
                delays.append(parsedate_to_datetime(retry).timestamp() - now)
            except (TypeError, ValueError, OverflowError):
                pass
    reset = headers.get("x-rate-limit-reset") or headers.get("x-ratelimit-reset")
    if reset is not None:
        try:
            delays.append(float(reset) - now)
        except (TypeError, ValueError):
            pass
    delays = [delay for delay in delays if math.isfinite(delay)]
    return max(0, math.ceil(max(delays))) if delays else None


def is_rate_limited(status, headers):
    headers = {str(k).lower(): v for k, v in headers.items()}
    return status == 429 or (status == 403 and (
        "retry-after" in headers or headers.get("x-ratelimit-remaining") == "0"
        or headers.get("x-rate-limit-remaining") == "0"))


def http_json_or_text(url, token=None, method="GET", body=None, text=False):
    headers = {"Accept": "application/json", "User-Agent": "DWTSPhotoJob/2.0"}
    if token:
        headers.update({"Authorization": f"Bearer {token}",
                        "X-GitHub-Api-Version": "2022-11-28"})
    if text:
        headers.update({
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml", "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://platform.twitter.com/",
        })
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, method=method, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode("utf-8")
            return raw if text else json.loads(raw)
    except urllib.error.HTTPError as exc:
        if is_rate_limited(exc.code, exc.headers):
            service = "GitHub" if urllib.parse.urlsplit(url).hostname == "api.github.com" else "X"
            raise RateLimitError(service, cooldown_seconds(exc.headers)) from exc
        raise


def fetch_posts(handle):
    html = http_json_or_text(
        f"https://syndication.twitter.com/srv/timeline-profile/screen-name/{handle}", text=True)
    match = re.search(r'<script[^>]*\bid=[\"\']__NEXT_DATA__[\"\'][^>]*>(.*?)</script>', html, re.S)
    if not match:
        raise PhotoError("X did not return the expected timeline data.")
    try:
        data = json.loads(match.group(1))
        entries = data["props"]["pageProps"]["timeline"]["entries"]
        tweets = [e["content"]["tweet"] for e in entries if e.get("type") == "tweet"]
        own = [t for t in tweets if not t.get("retweeted_status")]
        return sorted(own, key=lambda t: int(t["id_str"]), reverse=True)
    except (ValueError, KeyError, TypeError) as exc:
        raise PhotoError("X returned an unsupported timeline format.") from exc


def norm(value):
    return "".join(c for c in unicodedata.normalize("NFKD", value)
                   if not unicodedata.combining(c)).casefold()


def mentions(text, alias):
    return re.search(rf"(?<!\w){re.escape(norm(alias))}(?!\w)", text) is not None


def normalize_couples(value):
    if isinstance(value, dict):
        value = [{"star_name": star, "pro_name": pro} for star, pro in value.items()]
    if not isinstance(value, list) or not value:
        raise PhotoError("--couples must be a nonempty JSON object or list.")
    result, seen = [], set()
    for item in value:
        if not isinstance(item, dict):
            raise PhotoError("Each couple must contain star_name and pro_name.")
        pair = {}
        for key in ("star_name", "pro_name"):
            name = item.get(key)
            if not isinstance(name, str) or len(name.split()) < 2:
                raise PhotoError(f"{key} must include first and last names.")
            if any(c in name for c in "/\\") or any(ord(c) < 32 for c in name):
                raise PhotoError("Names must not contain path separators or control characters.")
            pair[key] = " ".join(name.split())
        key = (norm(pair["star_name"]), norm(pair["pro_name"]))
        if key in seen:
            raise PhotoError("The couples list contains a duplicate couple.")
        seen.add(key)
        result.append(pair)
    return result


def read_couples(argument):
    raw = Path(argument[1:]).read_text(encoding="utf-8") if argument.startswith("@") else argument
    return normalize_couples(json.loads(raw))


def couple_name(couple):
    return f"{couple['star_name']} and {couple['pro_name']}"


def find_couples(caption, couples):
    text = norm(caption)
    return [c for c in couples if mentions(text, c["star_name"]) and mentions(text, c["pro_name"])]


def gh(method, path, token, body=None):
    return http_json_or_text(f"https://api.github.com/repos/{GITHUB_REPO}{path}",
                             token=token, method=method, body=body)


def remote_files(folder, token):
    path = urllib.parse.quote(folder, safe="/")
    try:
        rows = gh("GET", f"/contents/{path}?ref={urllib.parse.quote(BRANCH, safe='')}", token)
        return [row["name"] for row in rows if row.get("type") == "file"]
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return []
        raise


def commit_files(files, message, token):
    """Stage all blobs and move the branch once. Never report success before PATCH."""
    entries = [{"path": repo_path, "mode": "100644", "type": "blob", "sha":
                gh("POST", "/git/blobs", token, {
                    "content": base64.b64encode(Path(local).read_bytes()).decode(),
                    "encoding": "base64"})["sha"]} for repo_path, local in files]
    branch = urllib.parse.quote(BRANCH, safe="")
    for attempt in range(3):
        head = gh("GET", f"/git/ref/heads/{branch}", token)["object"]["sha"]
        base_tree = gh("GET", f"/git/commits/{head}", token)["tree"]["sha"]
        tree = gh("POST", "/git/trees", token, {"base_tree": base_tree, "tree": entries})["sha"]
        commit = gh("POST", "/git/commits", token,
                    {"message": message, "tree": tree, "parents": [head]})["sha"]
        try:
            gh("PATCH", f"/git/refs/heads/{branch}", token, {"sha": commit, "force": False})
            return commit
        except urllib.error.HTTPError as exc:
            if exc.code != 422 or attempt == 2:
                raise
            # A branch race needs new filenames, not just a new parent commit.
            for repo_path, _ in files:
                folder, name = repo_path.rsplit("/", 1)
                if name in remote_files(folder, token):
                    raise PhotoError("An upload filename was taken by another run; retry with fresh numbering.") from exc


def load_state():
    state = json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else {"downloaded": {}}
    if not isinstance(state, dict) or not isinstance(state.get("downloaded"), dict):
        raise PhotoError("The existing photo state file has an unsupported format.")
    return state


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    # Preserve the old downloaded dictionary, with atomic replacement.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=STATE.parent, delete=False) as out:
        temporary = Path(out.name)
        json.dump(state, out, indent=2)
        out.write("\n")
    try:
        temporary.replace(STATE)
    finally:
        temporary.unlink(missing_ok=True)


def next_index(existing, name):
    pattern = re.compile(rf"^{re.escape(name)}-(\d+)\.\w+$")
    return max((int(m.group(1)) for filename in existing
                if (m := pattern.match(filename))), default=0) + 1


def photo_order(path):
    match = re.search(r"_(\d+)$", path.stem)
    return int(match.group(1)) if match else 0


def gallery_command():
    """Use gallery-dl's own Python so its existing configuration still works."""
    if importlib.util.find_spec("gallery_dl") is not None:
        return [sys.executable, str(Path(__file__).resolve()), "--_gallery-worker"]
    executable = shutil.which("gallery-dl")
    if not executable:
        raise PhotoError("gallery-dl was not found. Install it or add it to PATH.")
    with open(executable, "rb") as file:
        first_line = file.readline(4096).decode("utf-8", errors="replace").strip()
    if first_line.startswith("#!") and "python" in first_line.lower():
        return shlex.split(first_line[2:]) + [str(Path(__file__).resolve()), "--_gallery-worker"]
    raise PhotoError("Use a Python installation of gallery-dl so cooldown headers can be captured without waiting.")


def gallery_worker(arguments):
    """Internal child process: abort rate limits before gallery-dl can sleep/retry."""
    import gallery_dl
    import requests
    from gallery_dl import exception
    from gallery_dl.extractor import twitter

    class StopForCooldown(BaseException):
        def __init__(self, headers):
            self.seconds = cooldown_seconds(headers)

    original_send = requests.sessions.Session.send

    def guarded_send(session, request, **kwargs):
        response = original_send(session, request, **kwargs)
        if is_rate_limited(response.status_code, response.headers):
            raise StopForCooldown(response.headers)
        return response

    def abort_twitter_rate_limit(api, response):
        raise StopForCooldown(response.headers)

    requests.sessions.Session.send = guarded_send
    twitter.TwitterAPI._handle_ratelimit = abort_twitter_rate_limit
    sys.argv = ["gallery-dl"] + arguments
    try:
        gallery_dl.main()
    except StopForCooldown as exc:
        print(RATE_MARKER + json.dumps({"cooldown_seconds": exc.seconds}), file=sys.stderr)
        return 75
    except exception.AbortExtraction:
        return 1
    finally:
        requests.sessions.Session.send = original_send
    return 0


def download(url, dest):
    command = gallery_command() + [
        "--no-input", "--no-colors", "--no-postprocessors", "-R", "0",
        "-o", "extractor.twitter.retries-api=0", "-o", "extractor.twitter.ratelimit=abort",
        "-o", "extractor.twitter.archive=null",
        "-D", str(dest), url,
    ]
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as exc:
        raise PhotoError("Photo download exceeded its two-minute time limit; retry on a later run.") from exc
    for line in process.stderr.splitlines():
        if line.startswith(RATE_MARKER):
            raise RateLimitError("X photos", json.loads(line[len(RATE_MARKER):])["cooldown_seconds"])
    if process.returncode:
        # Do not echo subprocess logs: they may contain authentication details.
        raise PhotoError(f"gallery-dl could not finish this post (exit code {process.returncode}).")
    return sorted((p for p in Path(dest).rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_EXTS), key=photo_order)


def uploaded_file(path, commit=None):
    base = f"https://github.com/{GITHUB_REPO}/blob/" + urllib.parse.quote(commit or BRANCH, safe="")
    return {"path": path, "url": base + "/" + urllib.parse.quote(path, safe="/")}


def new_result(week, couples, dry_run):
    return {"script": "dwts-photos.py", "week": week, "dry_run": dry_run, "failed_run": False,
            "skip_next_run": False,
            "repository": GITHUB_REPO, "folder": f"{DANCES_DIR}/Week {week}",
            "uploaded_couples": [], "remaining_couples": list(couples),
            "planned_uploads": [], "errors": []}


def record_error(result, exc, stage, couple=None):
    result["failed_run"] = True
    error = {"stage": stage, "message": str(exc)}
    if couple:
        error.update(couple)
    if isinstance(exc, RateLimitError):
        error["service"] = exc.service
        error["cooldown_seconds"] = exc.seconds
        if exc.seconds is not None:
            result["skip_next_run"] = result["skip_next_run"] or exc.seconds > 300
        else:
            error["cooldown_known"] = False
    result["errors"].append(error)


def refresh_remaining(result):
    successful = {(c["star_name"], c["pro_name"]) for c in result["uploaded_couples"]}
    result["remaining_couples"] = [c for c in result["remaining_couples"]
                                  if (c["star_name"], c["pro_name"]) not in successful]


def run(week, couples, git_token, since=None, dry_run=False, external_state=None):
    couples = normalize_couples(couples)
    result = new_result(week, couples, dry_run)
    stage = "configuration"
    try:
        if week <= 0:
            raise PhotoError("--week must be a positive integer.")
        if not isinstance(git_token, str) or not git_token.strip():
            raise PhotoError("--git-token is required, including for dry runs.")
        day = datetime.strptime(since, "%Y-%m-%d") if since else datetime.now()
        since_time = day.replace(hour=0, minute=0, second=0, microsecond=0).astimezone()
        stage = "state"
        state = load_state() if external_state is None else external_state
        # Recover successes from earlier runs (including the old state format).
        if not dry_run and external_state is None:
            for couple in couples:
                name = couple_name(couple)
                previous = [(pid, entry) for pid, entry in state["downloaded"].items()
                            if isinstance(entry, dict) and entry.get("week") == week
                            and entry.get("couple") == name and entry.get("files")]
                if previous:
                    paths = [f"{result['folder']}/{filename}" for _, entry in previous for filename in entry["files"]]
                    result["uploaded_couples"].append({**couple,
                        "files": [uploaded_file(path) for path in paths]})
            refresh_remaining(result)
        targets = result["remaining_couples"]
        if not targets:
            return result
        stage = "timeline"
        posts = fetch_posts(HANDLE)
        stage = "github_listing"
        existing = remote_files(result["folder"], git_token)
        staged, done, uploaded = [], {}, {}
        with tempfile.TemporaryDirectory() as tmp:
            for post in posts:
                pid = str(post["id_str"])
                created = datetime.strptime(post["created_at"], "%a %b %d %H:%M:%S %z %Y")
                if created < since_time or pid in state["downloaded"]:
                    continue
                matches = find_couples(post.get("full_text") or post.get("text", ""), couples)
                if len(matches) != 1 or matches[0] not in targets:
                    continue
                couple = matches[0]
                name = couple_name(couple)
                if name in uploaded:
                    continue  # One photo-bearing post per couple is sufficient.
                url = f"https://x.com/{HANDLE}/status/{pid}"
                if dry_run:
                    result["planned_uploads"].append({**couple,
                        "post_url": url, "folder": result["folder"],
                        "filename_prefix": f"{name}-{next_index(existing, name)}"})
                    continue
                try:
                    photos = download(url, Path(tmp) / pid)
                except RateLimitError as exc:
                    record_error(result, exc, "download", couple)
                    break
                except (PhotoError, OSError) as exc:
                    record_error(result, exc, "download", couple)
                    continue
                if not photos:
                    continue  # Empty downloads are never successes or saved post IDs.
                number, filenames = next_index(existing, name), []
                info = uploaded.setdefault(name, {**couple, "files": [], "post_ids": [pid]})
                for photo in photos:
                    extension = ".jpeg" if photo.suffix.lower() in {".jpg", ".jpeg"} else photo.suffix.lower()
                    filename = f"{name}-{number}{extension}"
                    path = f"{result['folder']}/{filename}"
                    existing.append(filename)
                    filenames.append(filename)
                    staged.append((path, photo))
                    info["files"].append(path)
                    number += 1
                done[pid] = {"couple": name, "week": week, "files": filenames}
            if staged:
                stage = "github_upload"
                commit = commit_files(staged, f"Add Week {week} dance photos: {', '.join(uploaded)}", git_token)
                for info in uploaded.values():
                    info["commit_sha"] = commit
                    info["files"] = [uploaded_file(path, commit) for path in info["files"]]
                    result["uploaded_couples"].append(info)
                refresh_remaining(result)
                stage = "save_state"
                state["downloaded"].update(done)
                if external_state is None:
                    save_state(state)
        return result
    except (PhotoError, urllib.error.URLError, OSError, ValueError, KeyError, TypeError) as exc:
        record_error(result, exc, stage)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--week", type=int, required=True, help="Week number for Images/Dances/Week N.")
    parser.add_argument("--couples", required=True, metavar="JSON_OR_@FILE", help="Full-name couples JSON, inline or @filename.")
    parser.add_argument("--git-token", help="Optional override for DWTS_PHOTOS_GITHUB_TOKEN.")
    parser.add_argument("--since", help="Only posts on/after YYYY-MM-DD (default: today in the local timezone).")
    parser.add_argument("--dry-run", action="store_true", help="Preview matches without downloads, uploads, or state changes.")
    parser.add_argument("--print", dest="pretty", action="store_true", help="Indent the JSON output; default is compact JSON.")
    args = parser.parse_args(argv)
    try:
        from dotenv import load_dotenv
        load_dotenv(Path(__file__).resolve().parent / ".env")
    except ImportError:
        pass  # Explicit CLI tokens and exported environment variables still work.
    args.git_token = args.git_token or os.environ.get("DWTS_PHOTOS_GITHUB_TOKEN")
    try:
        couples = read_couples(args.couples)
        result = run(args.week, couples, args.git_token, args.since, args.dry_run)
    except (PhotoError, OSError, ValueError) as exc:
        result = new_result(args.week, [], args.dry_run)
        record_error(result, exc, "configuration")
    # Never allow a supplied token to be echoed in an error, subprocess output, etc.
    output = json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None,
                        separators=None if args.pretty else (",", ":"))
    print(output.replace(args.git_token, "[REDACTED]") if args.git_token else output)
    return 1 if result["failed_run"] else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--_gallery-worker":
        sys.exit(gallery_worker(sys.argv[2:]))
    sys.exit(main())
