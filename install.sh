#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/mediamtx.yml"
SCRIPT="/root/restream.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mediamtx.yml.backup-${STAMP}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG was not found." >&2
  exit 1
fi

python3 - "$CONFIG" "$SCRIPT" "$BACKUP" <<'PY'
from pathlib import Path
import re
import shlex
import sys

config_path = Path(sys.argv[1])
script_path = Path(sys.argv[2])
backup_path = Path(sys.argv[3])

text = config_path.read_text()

pattern = re.compile(
    r'(?ms)^(?P<indent>\s*)runOnReady:\s*/usr/bin/ffmpeg\s+(?P<command>.+?)\n(?P=indent)runOnReadyRestart:\s*true\s*$'
)
match = pattern.search(text)
if not match:
    raise SystemExit(
        "ERROR: current FFmpeg runOnReady block was not found. No files were changed."
    )

command = match.group("command")
indent = match.group("indent")
tee_match = re.search(r'-f\s+tee\s+"(?P<outputs>.+)"\s*$', command)
if not tee_match:
    raise SystemExit(
        "ERROR: tee output list was not found. No files were changed."
    )

outputs = []
for raw in tee_match.group("outputs").split("|"):
    value = re.sub(r'^\[[^\]]+\]', '', raw.strip())
    if not value.startswith(("rtmp://", "rtmps://")):
        raise SystemExit(
            f"ERROR: unsupported destination in existing config: {value!r}. No files were changed."
        )
    outputs.append(value)

if len(outputs) != 3:
    raise SystemExit(
        f"ERROR: expected exactly 3 destinations, found {len(outputs)}. No files were changed."
    )

backup_path.write_text(text)
quoted = [shlex.quote(url) for url in outputs]

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
    -f flv {quoted[0]} &
YOUTUBE_PID=$!

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
    -f flv {quoted[1]} &
TWITCH_PID=$!

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
    -f flv {quoted[2]} &
THIRD_PID=$!

wait -n "$YOUTUBE_PID" "$TWITCH_PID" "$THIRD_PID"
STATUS=$?
cleanup
exit "$STATUS"
'''

script_path.write_text(script)
script_path.chmod(0o700)

replacement = (
    f"{indent}runOnReady: {script_path}\n"
    f"{indent}runOnReadyRestart: true"
)
config_path.write_text(pattern.sub(replacement, text, count=1))

print(f"Backup created: {backup_path}")
print(f"Restream script created: {script_path}")
print(f"Updated: {config_path}")
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
  cp "$BACKUP" "$CONFIG"
  exit 1
fi

systemctl restart mediamtx
systemctl --no-pager --full status mediamtx

echo
echo "Installation complete."
echo "To follow logs: journalctl -fu mediamtx"
echo "Rollback command: cp '$BACKUP' '$CONFIG' && systemctl restart mediamtx"
