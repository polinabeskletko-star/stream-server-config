#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/mediamtx.yml"
SCRIPT="/root/restream.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
CONFIG_BACKUP="/root/mediamtx.yml.backup-${STAMP}"
SCRIPT_BACKUP="/root/restream.sh.backup-${STAMP}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG was not found." >&2
  exit 1
fi

python3 - "$CONFIG" "$SCRIPT" "$CONFIG_BACKUP" "$SCRIPT_BACKUP" <<'PY'
from pathlib import Path
import re
import shlex
import sys

config_path = Path(sys.argv[1])
script_path = Path(sys.argv[2])
config_backup_path = Path(sys.argv[3])
script_backup_path = Path(sys.argv[4])

config_text = config_path.read_text()
config_backup_path.write_text(config_text)

urls = []

# Upgrade an already-installed independent restream script.
if script_path.exists():
    old_script = script_path.read_text()
    script_backup_path.write_text(old_script)
    urls = re.findall(
        r'-f\s+flv\s+([^\s&]+)',
        old_script,
    )
    urls = [value.strip("'\"") for value in urls]

# First-time migration from the original single FFmpeg tee command.
if len(urls) != 3:
    pattern = re.compile(
        r'(?ms)^(?P<indent>\s*)runOnReady:\s*/usr/bin/ffmpeg\s+(?P<command>.+?)\n(?P=indent)runOnReadyRestart:\s*true\s*$'
    )
    match = pattern.search(config_text)
    if match:
        command = match.group("command")
        tee_match = re.search(r'-f\s+tee\s+"(?P<outputs>.+)"\s*$', command)
        if tee_match:
            urls = []
            for raw in tee_match.group("outputs").split("|"):
                value = re.sub(r'^\[[^\]]+\]', '', raw.strip())
                urls.append(value)

if len(urls) != 3:
    raise SystemExit(
        "ERROR: could not find exactly 3 existing RTMP destinations. No active files were changed."
    )

for value in urls:
    if not value.startswith(("rtmp://", "rtmps://")):
        raise SystemExit(
            f"ERROR: unsupported destination {value!r}. No active files were changed."
        )

def find_one(fragment: str) -> str:
    matches = [url for url in urls if fragment in url]
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: expected exactly one destination containing {fragment!r}; found {len(matches)}."
        )
    return matches[0]

youtube_url = find_one("youtube.com")
twitch_url = find_one("twitch.tv")
third_urls = [url for url in urls if url not in (youtube_url, twitch_url)]
if len(third_urls) != 1:
    raise SystemExit("ERROR: could not identify the third destination.")
third_url = third_urls[0]

quoted_youtube = shlex.quote(youtube_url)
quoted_twitch = shlex.quote(twitch_url)
quoted_third = shlex.quote(third_url)

script = f'''#!/usr/bin/env bash
set -u

SOURCE_URL="rtsp://127.0.0.1:8554/${{MTX_PATH}}"

cleanup() {{
    trap - INT TERM EXIT
    for pid in "${{YOUTUBE_PID:-}}" "${{TWITCH_PID:-}}" "${{THIRD_PID:-}}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -INT "$pid" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
}}

trap cleanup INT TERM EXIT

# YouTube is transcoded to produce predictable timestamps and a keyframe every 2 seconds.
/usr/bin/ffmpeg \\
    -hide_banner \\
    -loglevel info \\
    -nostdin \\
    -fflags +genpts \\
    -rtsp_transport tcp \\
    -i "$SOURCE_URL" \\
    -map 0:v:0 \\
    -map '0:a:0?' \\
    -c:v libx264 \\
    -preset veryfast \\
    -tune zerolatency \\
    -profile:v high \\
    -pix_fmt yuv420p \\
    -r 24 \\
    -g 48 \\
    -keyint_min 48 \\
    -sc_threshold 0 \\
    -b:v 4500k \\
    -maxrate 4500k \\
    -bufsize 9000k \\
    -c:a aac \\
    -b:a 128k \\
    -ar 48000 \\
    -avoid_negative_ts make_zero \\
    -flvflags no_duration_filesize \\
    -f flv {quoted_youtube} &
YOUTUBE_PID=$!

# Twitch keeps the original encoded stream.
/usr/bin/ffmpeg \\
    -hide_banner \\
    -loglevel info \\
    -nostdin \\
    -fflags +genpts \\
    -rtsp_transport tcp \\
    -i "$SOURCE_URL" \\
    -map 0:v:0 \\
    -map '0:a:0?' \\
    -c copy \\
    -avoid_negative_ts make_zero \\
    -flvflags no_duration_filesize \\
    -f flv {quoted_twitch} &
TWITCH_PID=$!

# The third platform keeps the original encoded stream.
/usr/bin/ffmpeg \\
    -hide_banner \\
    -loglevel info \\
    -nostdin \\
    -fflags +genpts \\
    -rtsp_transport tcp \\
    -i "$SOURCE_URL" \\
    -map 0:v:0 \\
    -map '0:a:0?' \\
    -c copy \\
    -avoid_negative_ts make_zero \\
    -flvflags no_duration_filesize \\
    -f flv {quoted_third} &
THIRD_PID=$!

wait -n "$YOUTUBE_PID" "$TWITCH_PID" "$THIRD_PID"
STATUS=$?
cleanup
exit "$STATUS"
'''

script_path.write_text(script)
script_path.chmod(0o700)

# Ensure MediaMTX runs the independent restream script.
run_pattern = re.compile(
    r'(?ms)^(?P<indent>\s*)runOnReady:\s*.*?\n(?P=indent)runOnReadyRestart:\s*true\s*$'
)
run_match = run_pattern.search(config_text)
if not run_match:
    raise SystemExit(
        "ERROR: runOnReady/runOnReadyRestart block was not found. Restream script was created, but MediaMTX config was not changed."
    )
indent = run_match.group("indent")
replacement = (
    f"{indent}runOnReady: {script_path}\n"
    f"{indent}runOnReadyRestart: true"
)
config_path.write_text(run_pattern.sub(replacement, config_text, count=1))

print(f"MediaMTX backup: {config_backup_path}")
if script_backup_path.exists():
    print(f"Previous restream script backup: {script_backup_path}")
print(f"Updated restream script: {script_path}")
print(f"Updated MediaMTX config: {config_path}")
PY

/usr/local/bin/mediamtx "$CONFIG" >/tmp/mediamtx-config-test.log 2>&1 &
TEST_PID=$!
sleep 2
if kill -0 "$TEST_PID" 2>/dev/null; then
  kill -INT "$TEST_PID" 2>/dev/null || true
  wait "$TEST_PID" 2>/dev/null || true
else
  echo "ERROR: MediaMTX configuration test failed." >&2
  cat /tmp/mediamtx-config-test.log >&2
  cp "$CONFIG_BACKUP" "$CONFIG"
  if [[ -f "$SCRIPT_BACKUP" ]]; then
    cp "$SCRIPT_BACKUP" "$SCRIPT"
    chmod 700 "$SCRIPT"
  fi
  exit 1
fi

systemctl restart mediamtx
systemctl --no-pager --full status mediamtx

echo
echo "Installation complete."
echo "YouTube now uses H.264 transcoding with a 2-second keyframe interval."
echo "Twitch and the third platform still use stream copy."
echo "Follow logs with: journalctl -fu mediamtx"
echo "Config rollback: cp '$CONFIG_BACKUP' '$CONFIG'"
if [[ -f "$SCRIPT_BACKUP" ]]; then
  echo "Script rollback: cp '$SCRIPT_BACKUP' '$SCRIPT' && chmod 700 '$SCRIPT'"
fi
echo "Then restart with: systemctl restart mediamtx"
