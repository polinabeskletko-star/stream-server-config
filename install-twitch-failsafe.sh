#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/mediamtx.yml"
RESTREAM="/root/restream.sh"
BRB_SCRIPT="/root/brb_fallback.sh"
READY_HOOK="/root/moblin_stream_ready.sh"
NOT_READY_HOOK="/root/moblin_stream_not_ready.sh"
BRB_VIDEO="/root/stream-server-config/BRB_Australia_IRL_10s.mp4"
TWITCH_SCRIPT="/root/twitch-failsafe.sh"
SERVICE_FILE="/etc/systemd/system/twitch-failsafe.service"
LOG_FILE="/var/log/twitch-failsafe.log"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/twitch-failsafe-backup-${STAMP}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

for required in "$CONFIG" "$RESTREAM" "$BRB_SCRIPT" "$READY_HOOK" "$NOT_READY_HOOK" "$BRB_VIDEO"; do
  if [[ ! -f "$required" ]]; then
    echo "ERROR: required file not found: $required" >&2
    exit 1
  fi
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg is not installed." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
cp "$CONFIG" "$BACKUP_DIR/mediamtx.yml"
cp "$RESTREAM" "$BACKUP_DIR/restream.sh"
cp "$BRB_SCRIPT" "$BACKUP_DIR/brb_fallback.sh"
cp "$READY_HOOK" "$BACKUP_DIR/moblin_stream_ready.sh"
cp "$NOT_READY_HOOK" "$BACKUP_DIR/moblin_stream_not_ready.sh"

TWITCH_URL="$(python3 - "$RESTREAM" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
m = re.search(r'(rtmp://live\.twitch\.tv/app/[^\s"\'&|]+)', text)
if not m:
    raise SystemExit('ERROR: Twitch destination was not found in /root/restream.sh')
print(m.group(1))
PY
)"

echo "Detected Twitch destination."

# 1) Add an always-available local path. It pulls live/test while Moblin is online
# and automatically supplies the BRB MP4 when that source is unavailable.
python3 - "$CONFIG" "$BRB_VIDEO" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
brb = sys.argv[2]
text = path.read_text()

# Remove an older copy if this installer is being rerun.
text = re.sub(
    r'(?ms)^\s{2}["\']?twitch-feed["\']?:\s*\n(?:\s{4}.*\n)*',
    '',
    text,
)

m = re.search(r'(?m)^paths:\s*$', text)
if not m:
    raise SystemExit('ERROR: paths: section not found in mediamtx.yml')

block = (
    '\n  "twitch-feed":\n'
    '    source: rtsp://127.0.0.1:8554/live/test\n'
    '    sourceOnDemand: false\n'
    '    rtspTransport: tcp\n'
    '    alwaysAvailable: true\n'
    f'    alwaysAvailableFile: {brb}\n'
)

# Append the dedicated path at the end of the configuration. It remains inside
# the paths map because paths is the final top-level section in this config.
text = text.rstrip() + block + '\n'
path.write_text(text)
PY

# 2) Remove Twitch from the old per-Moblin restream process. YouTube and the
# third platform stay exactly as before.
python3 - "$RESTREAM" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text()

text = re.sub(
    r'(?ms)\n# Twitch keeps the original encoded stream\.\n.*?TWITCH_PID=\$!\n',
    '\n',
    text,
)
text = text.replace(
    'for pid in "${YOUTUBE_PID:-}" "${TWITCH_PID:-}" "${THIRD_PID:-}"; do',
    'for pid in "${YOUTUBE_PID:-}" "${THIRD_PID:-}"; do',
)
text = text.replace(
    'wait -n "$YOUTUBE_PID" "$TWITCH_PID" "$THIRD_PID"',
    'wait -n "$YOUTUBE_PID" "$THIRD_PID"',
)
p.write_text(text)
PY
chmod 700 "$RESTREAM"

# 3) Remove Twitch from the old BRB tee publisher. Twitch will now receive BRB
# through the always-available twitch-feed without changing its RTMP session.
python3 - "$BRB_SCRIPT" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text()
text, n = re.subn(
    r'\|?\[f=flv:onfail=ignore\]rtmp://live\.twitch\.tv/app/[^|\s"\']+',
    '',
    text,
)
if n == 0:
    print('WARNING: no Twitch destination found in brb_fallback.sh; continuing.')
# Clean up accidental duplicated separators.
text = text.replace('||', '|')
p.write_text(text)
PY
chmod 700 "$BRB_SCRIPT"

# 4) Persistent Twitch publisher. During a session this process reads one path
# that never disappears; MediaMTX swaps between live/test and the BRB MP4.
cat > "$TWITCH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

exec /usr/bin/ffmpeg \\
  -hide_banner \\
  -loglevel info \\
  -nostdin \\
  -fflags +genpts \\
  -rtsp_transport tcp \\
  -i rtsp://127.0.0.1:8554/twitch-feed \\
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
  -f flv '$TWITCH_URL'
EOF
chmod 700 "$TWITCH_SCRIPT"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Persistent Twitch failsafe publisher
After=network-online.target mediamtx.service
Requires=mediamtx.service

[Service]
Type=simple
ExecStart=$TWITCH_SCRIPT
Restart=always
RestartSec=2
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

# 5) Start Twitch when a Moblin session starts. systemctl start is idempotent,
# so a temporary Moblin reconnect does NOT restart the Twitch RTMP connection.
python3 - "$READY_HOOK" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = 'systemctl start twitch-failsafe.service'
if marker not in text:
    needle = 'echo "===== $(date --iso-8601=seconds) Moblin stream READY ====="\n'
    if needle not in text:
        raise SystemExit('ERROR: READY hook insertion point not found')
    text = text.replace(
        needle,
        needle + '\n  systemctl start twitch-failsafe.service\n  echo "Ensured persistent Twitch publisher is running."\n',
        1,
    )
p.write_text(text)
PY
chmod 700 "$READY_HOOK"

# 6) Stop Twitch only after the existing 180-second grace period expires.
# Thus short outages keep the SAME Twitch ingest connection alive.
python3 - "$NOT_READY_HOOK" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = 'systemctl stop twitch-failsafe.service'
if marker not in text:
    needle = 'echo "Completing YouTube broadcast after the 3-minute grace period."\n'
    if needle not in text:
        raise SystemExit('ERROR: NOT READY hook insertion point not found')
    text = text.replace(
        needle,
        'systemctl stop twitch-failsafe.service\n'
        '    echo "Stopped persistent Twitch publisher after the 3-minute grace period."\n\n    ' + needle,
        1,
    )
p.write_text(text)
PY
chmod 700 "$NOT_READY_HOOK"

systemctl daemon-reload
systemctl disable twitch-failsafe.service >/dev/null 2>&1 || true
systemctl stop twitch-failsafe.service >/dev/null 2>&1 || true

# Restart MediaMTX so the new path is loaded. If startup fails, restore the
# original configuration and leave the service in its previous state.
if ! systemctl restart mediamtx; then
  echo "ERROR: MediaMTX failed to restart. Restoring configuration backup." >&2
  cp "$BACKUP_DIR/mediamtx.yml" "$CONFIG"
  systemctl restart mediamtx || true
  exit 1
fi
sleep 1
if ! systemctl is-active --quiet mediamtx; then
  echo "ERROR: MediaMTX is not active. Restoring configuration backup." >&2
  cp "$BACKUP_DIR/mediamtx.yml" "$CONFIG"
  systemctl restart mediamtx || true
  exit 1
fi

echo
echo "Persistent Twitch failsafe installed."
echo "Twitch is no longer launched by /root/restream.sh."
echo "During an active Moblin session, twitch-failsafe.service keeps one Twitch RTMP connection open."
echo "If Moblin disappears, twitch-feed automatically serves the BRB MP4."
echo "If Moblin returns within 180 seconds, the same Twitch service keeps running."
echo "If Moblin stays offline for 180 seconds, the existing timer stops Twitch and completes YouTube."
echo "Twitch log: $LOG_FILE"
echo "Backup directory: $BACKUP_DIR"
echo
echo "Test after installation with:"
echo "  systemctl status mediamtx --no-pager -l"
echo "  systemctl status twitch-failsafe --no-pager -l"
echo "  tail -n 80 $LOG_FILE"
