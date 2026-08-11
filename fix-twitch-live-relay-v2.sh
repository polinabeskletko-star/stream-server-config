#!/usr/bin/env bash
set -euo pipefail

RELAY_SCRIPT="/root/twitch-live-relay.sh"
RELAY_SERVICE="/etc/systemd/system/twitch-live-relay.service"
LOG_FILE="/var/log/twitch-live-relay.log"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/twitch-live-relay-v2-backup-${STAMP}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

if [[ ! -f "$RELAY_SERVICE" ]]; then
  echo "ERROR: $RELAY_SERVICE not found. Install the Twitch failsafe first." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
[[ -f "$RELAY_SCRIPT" ]] && cp "$RELAY_SCRIPT" "$BACKUP_DIR/twitch-live-relay.sh"
cp "$RELAY_SERVICE" "$BACKUP_DIR/twitch-live-relay.service"

cat > "$RELAY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Read Moblin from MediaMTX, normalize it to the same kind of tracks used by
# the BRB fallback (H.264 + AAC stereo/48 kHz), and publish it back to
# MediaMTX through local RTMP. RTMP is intentionally used for publishing here
# because MediaMTX already accepts H.264/AAC over RTMP reliably.
exec /usr/bin/ffmpeg \
  -hide_banner \
  -loglevel info \
  -nostdin \
  -fflags +genpts \
  -rtsp_transport tcp \
  -i rtsp://127.0.0.1:8554/live/test \
  -map 0:v:0 \
  -map '0:a:0?' \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30" \
  -c:v libx264 \
  -preset veryfast \
  -tune zerolatency \
  -profile:v high \
  -pix_fmt yuv420p \
  -g 60 \
  -keyint_min 60 \
  -sc_threshold 0 \
  -b:v 4500k \
  -maxrate 4500k \
  -bufsize 9000k \
  -c:a aac \
  -b:a 128k \
  -ar 48000 \
  -ac 2 \
  -avoid_negative_ts make_zero \
  -flvflags no_duration_filesize \
  -f flv \
  rtmp://127.0.0.1:1935/twitch-feed
EOF
chmod 700 "$RELAY_SCRIPT"

# Clear only this relay's old error log so the next check is unambiguous.
: > "$LOG_FILE"

systemctl daemon-reload
systemctl restart twitch-live-relay.service
sleep 4

if ! systemctl is-active --quiet twitch-live-relay.service; then
  echo "ERROR: twitch-live-relay.service did not stay active." >&2
  systemctl --no-pager --full status twitch-live-relay.service >&2 || true
  echo "--- relay log ---" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi

echo
echo "Twitch live relay v2 installed."
echo "Live relay now publishes H.264/AAC stereo to MediaMTX over local RTMP."
echo "Twitch failsafe itself was not restarted."
echo "If Moblin is currently online, Twitch should switch from BRB to live shortly."
echo "Relay log: $LOG_FILE"
echo "Backup: $BACKUP_DIR"
