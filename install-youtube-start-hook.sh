#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/mediamtx.yml"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_PY_SOURCE="$BASE_DIR/start_youtube.py"
TELEGRAM_NOTIFY_SOURCE="$BASE_DIR/notify_telegram_stream_start.sh"
START_PY="/root/start_youtube.py"
TELEGRAM_NOTIFY="/root/notify_telegram_stream_start.sh"
READY_HOOK="/root/start_youtube_on_ready.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
CONFIG_BACKUP="/root/mediamtx.yml.backup-youtube-start-${STAMP}"
LOG_FILE="/var/log/youtube-start.log"
TELEGRAM_LOG_FILE="/var/log/telegram-stream-notify.log"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

for required in \
  "$CONFIG" \
  "$START_PY_SOURCE" \
  "$TELEGRAM_NOTIFY_SOURCE" \
  /root/restream.sh \
  /root/youtube-token.json \
  /root/youtube-venv/bin/python; do
  if [[ ! -e "$required" ]]; then
    echo "ERROR: required file was not found: $required" >&2
    exit 1
  fi
done

cp "$CONFIG" "$CONFIG_BACKUP"
install -m 700 "$START_PY_SOURCE" "$START_PY"
install -m 700 "$TELEGRAM_NOTIFY_SOURCE" "$TELEGRAM_NOTIFY"

cat > "$READY_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -u

LOG_FILE="/var/log/youtube-start.log"
TELEGRAM_LOG_FILE="/var/log/telegram-stream-notify.log"

{
  echo ""
  echo "===== $(date --iso-8601=seconds) MediaMTX stream ready ====="
  /root/notify_telegram_stream_start.sh
} >>"$TELEGRAM_LOG_FILE" 2>&1 &

{
  echo ""
  echo "===== $(date --iso-8601=seconds) MediaMTX stream ready ====="
  /root/youtube-venv/bin/python /root/start_youtube.py
} >>"$LOG_FILE" 2>&1 &

exec /root/restream.sh
HOOK
chmod 700 "$READY_HOOK"

python3 - "$CONFIG" "$READY_HOOK" <<'PY'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
hook_path = sys.argv[2]
text = config_path.read_text()

pattern = re.compile(
    r'(?m)^(?P<indent>\s*)runOnReady:\s*/root/(?:restream\.sh|start_youtube_on_ready\.sh)\s*$'
)
match = pattern.search(text)
if not match:
    raise SystemExit(
        "ERROR: active runOnReady entry for /root/restream.sh was not found. Config was not changed."
    )

indent = match.group("indent")
text = pattern.sub(f"{indent}runOnReady: {hook_path}", text, count=1)
config_path.write_text(text)
PY

systemctl restart mediamtx
systemctl --no-pager --full status mediamtx

echo
echo "YouTube automatic start + Telegram notification hook installed."
echo "When Moblin input appears, MediaMTX will run: $READY_HOOK"
echo "YouTube log: $LOG_FILE"
echo "Telegram log: $TELEGRAM_LOG_FILE"
echo "Telegram secret file expected at: /root/telegram-webhook.env"
echo "Rollback: cp '$CONFIG_BACKUP' '$CONFIG' && systemctl restart mediamtx"
