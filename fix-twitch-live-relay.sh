#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/mediamtx.yml"
READY_HOOK="/root/moblin_stream_ready.sh"
NOT_READY_HOOK="/root/moblin_stream_not_ready.sh"
RELAY_SCRIPT="/root/twitch-live-relay.sh"
RELAY_SERVICE="/etc/systemd/system/twitch-live-relay.service"
BRB_VIDEO="/root/stream-server-config/BRB_Australia_IRL_10s.mp4"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/twitch-live-relay-backup-${STAMP}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

for f in "$CONFIG" "$READY_HOOK" "$NOT_READY_HOOK" "$BRB_VIDEO"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

mkdir -p "$BACKUP_DIR"
cp "$CONFIG" "$BACKUP_DIR/mediamtx.yml"
cp "$READY_HOOK" "$BACKUP_DIR/moblin_stream_ready.sh"
cp "$NOT_READY_HOOK" "$BACKUP_DIR/moblin_stream_not_ready.sh"

# Replace twitch-feed with a publisher-driven always-available path.
# The live relay will publish Moblin into this path. When the relay disappears,
# MediaMTX keeps readers connected and serves the BRB file instead.
python3 - "$CONFIG" "$BRB_VIDEO" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
brb = sys.argv[2]
text = p.read_text()

pattern = re.compile(
    r'(?ms)^\s{2}["\']?twitch-feed["\']?:\s*\n(?:\s{4}.*\n)*'
)
text, n = pattern.subn('', text)
if n == 0:
    print('WARNING: existing twitch-feed block not found; adding a fresh one.')

block = (
    '\n  "twitch-feed":\n'
    '    alwaysAvailable: true\n'
    f'    alwaysAvailableFile: {brb}\n'
)
text = text.rstrip() + block + '\n'
p.write_text(text)
PY

cat > "$RELAY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec /usr/bin/ffmpeg \
  -hide_banner \
  -loglevel warning \
  -nostdin \
  -fflags +genpts \
  -rtsp_transport tcp \
  -i rtsp://127.0.0.1:8554/live/test \
  -map 0:v:0 \
  -map '0:a:0?' \
  -c copy \
  -avoid_negative_ts make_zero \
  -f rtsp \
  -rtsp_transport tcp \
  rtsp://127.0.0.1:8554/twitch-feed
EOF
chmod 700 "$RELAY_SCRIPT"

cat > "$RELAY_SERVICE" <<EOF
[Unit]
Description=Moblin to Twitch failsafe live relay
After=mediamtx.service
Requires=mediamtx.service

[Service]
Type=simple
ExecStart=$RELAY_SCRIPT
Restart=always
RestartSec=2
StandardOutput=append:/var/log/twitch-live-relay.log
StandardError=append:/var/log/twitch-live-relay.log

[Install]
WantedBy=multi-user.target
EOF

# Start/ensure relay together with persistent Twitch publisher on READY.
python3 - "$READY_HOOK" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = 'systemctl start twitch-live-relay.service'
if marker not in text:
    needle = 'systemctl start twitch-failsafe.service\n'
    if needle not in text:
        raise SystemExit('ERROR: twitch-failsafe start marker not found in READY hook')
    text = text.replace(
        needle,
        needle + '  systemctl start twitch-live-relay.service\n  echo "Ensured Twitch live relay is running."\n',
        1,
    )
p.write_text(text)
PY

# Stop relay only when the existing 180-second grace period really expires.
python3 - "$NOT_READY_HOOK" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = 'systemctl stop twitch-live-relay.service'
if marker not in text:
    needle = 'systemctl stop twitch-failsafe.service\n'
    if needle not in text:
        raise SystemExit('ERROR: twitch-failsafe stop marker not found in NOT READY hook')
    text = text.replace(
        needle,
        'systemctl stop twitch-live-relay.service\n    ' + needle,
        1,
    )
p.write_text(text)
PY

chmod 700 "$READY_HOOK" "$NOT_READY_HOOK"

systemctl daemon-reload
systemctl stop twitch-live-relay.service >/dev/null 2>&1 || true

# Restart MediaMTX to load the publisher-driven twitch-feed path.
if ! systemctl restart mediamtx; then
  echo "ERROR: MediaMTX restart failed; restoring config." >&2
  cp "$BACKUP_DIR/mediamtx.yml" "$CONFIG"
  systemctl restart mediamtx || true
  exit 1
fi
sleep 1

if ! systemctl is-active --quiet mediamtx; then
  echo "ERROR: MediaMTX is not active; restoring config." >&2
  cp "$BACKUP_DIR/mediamtx.yml" "$CONFIG"
  systemctl restart mediamtx || true
  exit 1
fi

echo
echo "Twitch live relay fix installed."
echo "twitch-feed is now publisher-driven with alwaysAvailable BRB fallback."
echo "Moblin READY -> live relay publishes live/test into twitch-feed."
echo "Moblin outage -> relay loses source, twitch-feed serves BRB without dropping Twitch reader."
echo "Moblin returns -> relay reconnects and live video replaces BRB."
echo "After 180 seconds offline -> existing hook stops Twitch and relay."
echo "Relay log: /var/log/twitch-live-relay.log"
echo "Backup: $BACKUP_DIR"
