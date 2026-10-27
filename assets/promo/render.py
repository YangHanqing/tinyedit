#!/usr/bin/env python3
"""Render the editable poster with a local Chromium browser; no packages required."""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scale', type=int, default=2, choices=(1, 2, 3))
parser.add_argument('--output', type=Path, default=ROOT / 'assets/screenshots/features.png')
args = parser.parse_args()
candidates = [
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    shutil.which('chromium'), shutil.which('chromium-browser'), shutil.which('google-chrome'),
]
browser = next((p for p in candidates if p and Path(p).is_file()), None)
if not browser:
    raise SystemExit('Install Microsoft Edge, Google Chrome, or Chromium to render the poster.')
output = args.output.resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='tinyedit-promo-') as profile:
    capture = Path(profile) / 'poster.png'
    command = [browser, '--headless', '--disable-gpu', '--hide-scrollbars',
               '--no-first-run', '--no-default-browser-check', '--allow-file-access-from-files',
               '--virtual-time-budget=1500', '--window-size=1600,1500',
               f'--force-device-scale-factor={args.scale}', f'--user-data-dir={profile}/browser',
               f'--screenshot={capture}', (HERE / 'features.html').as_uri()]
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                if capture.exists() and capture.stat().st_size > 1000:
                    # Chromium may stay alive after writing the screenshot.
                    time.sleep(0.5)
                    shutil.copyfile(capture, output)
                    break
                if proc.poll() is not None:
                    log.seek(0)
                    raise SystemExit(log.read().decode(errors='replace')[-3000:])
                time.sleep(0.1)
            else:
                raise SystemExit('Poster rendering timed out.')
        finally:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
print(f'{output} ({1600 * args.scale} × {1500 * args.scale})')
