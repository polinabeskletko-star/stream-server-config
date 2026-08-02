#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/mediamtx.yml"
RESTREAM="/root/restream.sh"
VIDEO="/root/stream-server-config/BRB_Australia_IRL_10s.mp4"
START_PY="/root/start_youtube.py"
COMPLETE_PY="/root/complete_youtube.py"
PYTHON="/root/youtube-venv/bin/python"

READY_HOOK="/root/moblin_stream_ready.sh"
NOT_READY_HOOK="/root/moblin_stream_not_ready.sh"
FALLBACK_SCRIPT="/root/brb_fallback.sh"

STATE_DIR="/run/moblin-brb"
LOG_FILE="/var/log/moblin-brb.log"
TIMEOUT_SECONDS=180

STAMP="$(date +%Y%m%d-%H%M%S)"
CONFIG_BACKUP="/root/mediamtx.yml.backup-brb-${STAMP}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

for required in "$CONFIG" "$RESTREAM" "$VIDEO" "$START_PY" "$COMPLETE_PY" "$PYTHON"; do
  if [[ ! -e "$required" ]]; then
    echo "ERROR: required file was not found: $required" >&2
    exit 1
  fi
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg is not installed." >&2
  exit 1
fi

cp "$CONFIG" "$CONFIG_BACKUP"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Extract the three existing platform destinations from the active restream script.
mapfile -t DESTINATIONS < <(python3 - "$RESTREAM" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
urls = [value.strip("'\"") for value in re.findall(r'-f\s+flv\s+([^\s&]+)', text)]

# Keep order while removing duplicates.
unique = []
for url in urls:
    if url not in unique:
        unique.append(url)

if len(unique) != 3:
    raise SystemExit(f"ERROR: expected 3 RTMP destinations in {sys.argv[1]}, found {len(unique)}")

for url in unique:
    if not url.startswith(("rtmp://", "rtmps://")):
        raise SystemExit(f"ERROR: unsupported destination: {url}")
    print(url)
PY
)

if [[ ${#DESTINATIONS[@]} -ne 3 ]]; then
  echo "ERROR: could not extract exactly 3 streaming destinations." >&2
  exit 1
fi

# Create a detached fallback publisher. It loops the prepared H.264/AAC MP4 and
# publishes one encoded stream to all three destinations through the tee muxer.
{
  cat <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

VIDEO="/root/stream-server-config/BRB_Australia_IRL_10s.mp4"
LOG_FILE="/var/log/moblin-brb.log"

if [[ ! -f "$VIDEO" ]]; then
  echo "$(date --iso-8601=seconds) ERROR: fallback video not found: $VIDEO" >>"$LOG_FILE"
  exit 1
fi

exec /usr/bin/ffmpeg \
  -hide_banner \
  -loglevel warning \
  -nostdin \
  -re \
  -stream_loop -1 \
  -fflags +genpts \
  -i "$VIDEO" \
  -map 0:v:0 \
  -map 0:a:0 \
  -c copy \
  -avoid_negative_ts make_zero \
  -f tee \
SCRIPT

  printf '  %q\n' "[f=flv:onfail=ignore]${DESTINATIONS[0]}|[f=flv:onfail=ignore]${DESTINATIONS[1]}|[f=flv:onfail=ignore]${DESTINATIONS[2]}"
} > "$FALLBACK_SCRIPT"
chmod 700 "$FALLBACK_SCRIPT"

cat > "$READY_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -u

STATE_DIR="/run/moblin-brb"
LOG_FILE="/var/log/moblin-brb.log"

mkdir -p "$STATE_DIR"

{
  echo ""
  echo "===== $(date --iso-8601=seconds) Moblin stream READY ====="

  # Cancel the 3-minute completion timer.
  rm -f "$STATE_DIR/offline"

  if [[ -f "$STATE_DIR/timer.pid" ]]; then
    TIMER_PID="$(cat "$STATE_DIR/timer.pid" 2>/dev/null || true)"
    if [[ -n "$TIMER_PID" ]] && kill -0 "$TIMER_PID" 2>/dev/null; then
      kill "$TIMER_PID" 2>/dev/null || true
      echo "Cancelled delayed YouTube completion timer (PID $TIMER_PID)."
    fi
    rm -f "$STATE_DIR/timer.pid"
  fi

  # Stop the BRB publisher before the live restream reconnects to the same keys.
  if [[ -f "$STATE_DIR/fallback.pid" ]]; then
    FALLBACK_PID="$(cat "$STATE_DIR/fallback.pid" 2>/dev/null || true)"
    if [[ -n "$FALLBACK_PID" ]] && kill -0 "$FALLBACK_PID" 2>/dev/null; then
      kill -INT "$FALLBACK_PID" 2>/dev/null || true
      for _ in {1..20}; do
        kill -0 "$FALLBACK_PID" 2>/dev/null || break
        sleep 0.1
      done
      kill -TERM "$FALLBACK_PID" 2>/dev/null || true
      echo "Stopped BRB publisher (PID $FALLBACK_PID)."
    fi
    rm -f "$STATE_DIR/fallback.pid"
  fi

  # Existing behavior is preserved: create/reuse and start a YouTube broadcast.
  /root/youtube-venv/bin/python /root/start_youtube.py
} >>"$LOG_FILE" 2>&1 &

# Existing live restream to YouTube, Twitch and the third platform.
exec /root/restream.sh
HOOK
chmod 700 "$READY_HOOK"

cat > "$NOT_READY_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -u

STATE_DIR="/run/moblin-brb"
LOG_FILE="/var/log/moblin-brb.log"
TIMEOUT_SECONDS=180

mkdir -p "$STATE_DIR"

{
  echo ""
  echo "===== $(date --iso-8601=seconds) Moblin stream NOT READY ====="

  # Ignore duplicate not-ready events while the same outage is already handled.
  if [[ -f "$STATE_DIR/offline" ]]; then
    echo "Outage handling is already active; duplicate event ignored."
    exit 0
  fi

  touch "$STATE_DIR/offline"

  # Give the live FFmpeg processes time to release the platform connections.
  sleep 2

  nohup /root/brb_fallback.sh >>"$LOG_FILE" 2>&1 </dev/null &
  FALLBACK_PID=$!
  echo "$FALLBACK_PID" > "$STATE_DIR/fallback.pid"
  echo "Started BRB publisher (PID $FALLBACK_PID)."
  echo "YouTube will remain live for up to $TIMEOUT_SECONDS seconds."

  (
    sleep "$TIMEOUT_SECONDS"

    # The READY hook removes this marker. If it is gone, Moblin returned.
    [[ -f "$STATE_DIR/offline" ]] || exit 0

    echo "$(date --iso-8601=seconds) Moblin did not return within $TIMEOUT_SECONDS seconds."

    if [[ -f "$STATE_DIR/fallback.pid" ]]; then
      PID="$(cat "$STATE_DIR/fallback.pid" 2>/dev/null || true)"
      if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 1
        kill -TERM "$PID" 2>/dev/null || true
      fi
    fi

    rm -f "$STATE_DIR/fallback.pid" "$STATE_DIR/offline" "$STATE_DIR/timer.pid"

    echo "Completing YouTube broadcast after the 3-minute grace period."
    /root/youtube-venv/bin/python /root/complete_youtube.py
  ) >>"$LOG_FILE" 2>&1 &

  TIMER_PID=$!
  echo "$TIMER_PID" > "$STATE_DIR/timer.pid"
  echo "Started delayed completion timer (PID $TIMER_PID)."
} >>"$LOG_FILE" 2>&1 &

exit 0
HOOK
chmod 700 "$NOT_READY_HOOK"

python3 - "$CONFIG" "$READY_HOOK" "$NOT_READY_HOOK" <<'PY'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
ready_hook = sys.argv[2]
not_ready_hook = sys.argv[3]
text = config_path.read_text()

# Update only the active live/test hooks, not the commented defaults.
path_pattern = re.compile(
    r'(?ms)(^\s*["\']?live/test["\']?:\s*\n)(?P<body>.*?)(?=^\s{0,2}["\']?[^\s#][^:\n]*["\']?:\s*(?:\n|$)|\Z)'
)
match = path_pattern.search(text)
if not match:
    raise SystemExit("ERROR: active live/test path block was not found. Config was not changed.")

body = match.group("body")
indent_match = re.search(r'(?m)^(\s+)runOnReady:', body)
if not indent_match:
    raise SystemExit("ERROR: runOnReady was not found inside live/test. Config was not changed.")
indent = indent_match.group(1)

if re.search(r'(?m)^\s*runOnReady:', body):
    body = re.sub(r'(?m)^\s*runOnReady:.*$', f'{indent}runOnReady: {ready_hook}', body, count=1)
else:
    body += f'{indent}runOnReady: {ready_hook}\n'

if re.search(r'(?m)^\s*runOnReadyRestart:', body):
    body = re.sub(r'(?m)^\s*runOnReadyRestart:.*$', f'{indent}runOnReadyRestart: true', body, count=1)
else:
    body += f'{indent}runOnReadyRestart: true\n'

if re.search(r'(?m)^\s*runOnNotReady:', body):
    body = re.sub(r'(?m)^\s*runOnNotReady:.*$', f'{indent}runOnNotReady: {not_ready_hook}', body, count=1)
else:
    body += f'{indent}runOnNotReady: {not_ready_hook}\n'

text = text[:match.start("body")] + body + text[match.end("body"):]
config_path.write_text(text)
PY

# Validate the config before restarting the active service.
/usr/local/bin/mediamtx "$CONFIG" >/tmp/mediamtx-brb-config-test.log 2>&1 &
TEST_PID=$!
sleep 2
if kill -0 "$TEST_PID" 2>/dev/null; then
  kill -INT "$TEST_PID" 2>/dev/null || true
  wait "$TEST_PID" 2>/dev/null || true
else
  echo "ERROR: MediaMTX configuration test failed." >&2
  cat /tmp/mediamtx-brb-config-test.log >&2
  cp "$CONFIG_BACKUP" "$CONFIG"
  exit 1
fi

systemctl restart mediamtx
systemctl --no-pager --full status mediamtx

echo
echo "BRB fallback installed."
echo "Temporary outage: BRB video starts immediately."
echo "Moblin returns within 180 seconds: BRB stops and the same broadcast continues."
echo "Moblin remains offline for 180 seconds: BRB stops and YouTube is completed through the existing API hook."
echo "Log: $LOG_FILE"
echo "Rollback: cp '$CONFIG_BACKUP' '$CONFIG' && systemctl restart mediamtx"
