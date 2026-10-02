"""Smoke-test the exact gallery-dl entry point used by dwts-photos.py."""

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import gallery_dl
import requests  # noqa: F401 - also required by dwts-photos.py's gallery worker
from gallery_dl.extractor import twitter


script = Path(__file__).with_name("dwts-photos.py")
spec = importlib.util.spec_from_file_location("dwts_photos", script)
photos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(photos)

assert hasattr(twitter.TwitterAPI, "_handle_ratelimit"), "gallery-dl Twitter API hook changed"
command = photos.gallery_command()
assert command[:2] == [sys.executable, str(script.resolve())], command
version = subprocess.run(command + ["--version"], capture_output=True, text=True, check=True)
assert gallery_dl.__version__ in version.stdout, version.stdout

# Confirm the GitHub Actions secret can be supplied without a --git-token argument.
secret = "runner-test-token"
output = io.StringIO()
with patch.dict(os.environ, {"DWTS_GITHUB_TOKEN": secret}), \
        patch.object(photos, "run", return_value={"failed_run": False, "token": secret}) as run, \
        contextlib.redirect_stdout(output):
    assert photos.main(["--week", "4", "--couples", '{"Amber Glenn":"Pasha Pashkov"}']) == 0
assert run.call_args.args[2] == secret
assert secret not in output.getvalue()
assert "[REDACTED]" in output.getvalue()

print(f"gallery-dl {gallery_dl.__version__} and DWTS photo worker are ready")
