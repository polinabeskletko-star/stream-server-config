#!/usr/bin/env bash
# Install Telegram announcement tracking in existing MediaMTX BRB hooks.
# Does not modify mediamtx.yml, streaming destinations, or restream.sh.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READY="/root/moblin_stream_ready.sh"
NOT_READY="/root/moblin_stream_not_ready.sh"
CONFIG="/root/mediamtx.yml"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/telegram-lifecycle-backup-$STAMP"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root on the streaming server." >&2
  exit 1
fi
for p in "$CONFIG" "$READY" "$NOT_READY" "$BASE_DIR/notify_telegram_stream_start.sh" "$BASE_DIR/notify_telegram_stream_end.sh" "/root/telegram-webhook.env"; do
  if [[ ! -f "$p" ]]; then
    echo "Missing required file: $p; no changes made." >&2
    exit 1
  fi
done

# Only work with the precise BRB hook pair whose semantics are known.
python3 - "$CONFIG" "$READY" "$NOT_READY" <<'PY'
from pathlib import Path
import sys
config = Path(sys.argv[1]).read_text()
ready = Path(sys.argv[2]).read_text()
stop = Path(sys.argv[3]).read_text()
checks = [
    (config.count("runOnReady: /root/moblin_stream_ready.sh") == 1, "active READY hook does not match"),
    (config.count("runOnNotReady: /root/moblin_stream_not_ready.sh") == 1, "active NOT READY hook does not match"),
    ('  rm -f "$STATE_DIR/offline"' in ready, "READY reconnect marker not found"),
    ('  # Existing behavior is preserved: create/reuse and start a YouTube broadcast.' in ready, "READY insertion point not found"),
    ('    /root/youtube-venv/bin/python /root/complete_youtube.py' in stop, "NOT READY completion call not found"),
]
for ok, err in checks:
    if not ok: raise SystemExit("ABORT: " + err)
print("Existing hooks verified; safe to add Telegram lifecycle calls.")
PY

mkdir -m 700 "$BACKUP"
cp -p "$READY" "$NOT_READY" "$BACKUP/"
install -m 700 "$BASE_DIR/notify_telegram_stream_start.sh" /root/notify_telegram_stream_start.sh
install -m 700 "$BASE_DIR/notify_telegram_stream_end.sh" /root/notify_telegram_stream_end.sh

python3 - "$READY" "$NOT_READY" <<'PY'
from pathlib import Path
import sys
ready, stop = map(Path,sys.argv[1:])
r = ready.read_text()
s = stop.read_text()
start = '  /root/notify_telegram_stream_start.sh >> /var/log/telegram-stream-notify.log 2>&1 || true\n'
end = '    /root/notify_telegram_stream_end.sh >> /var/log/telegram-stream-notify.log 2>&1 || true\n'
if start not in r:
    anchor = '  # Existing behavior is preserved: create/reuse and start a YouTube broadcast.'
    r = r.replace(anchor, '  # Announce only after reconnect handling has been cancelled.\n'+start+'\n'+anchor, 1)
if end not in s:
    anchor = '    /root/youtube-venv/bin/python /root/complete_youtube.py\n'
    s = s.replace(anchor,anchor+end,1)
ready.write_text(r)
stop.write_text(s)
PY

bash -n "$READY" "$NOT_READY" /root/notify_telegram_stream_start.sh /root/notify_telegram_stream_end.sh
chmod 700 "$READY" "$NOT_READY"
echo "Installed Telegram stream lifecycle hook calls."
echo "BRB and MediaMTX services were not restarted."
echo "Backup: $BACKUP"
echo "Log: /var/log/telegram-stream-notify.log"
