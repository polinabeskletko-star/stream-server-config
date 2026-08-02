#!/usr/bin/env bash
set -euo pipefail

RESTREAM="/root/restream.sh"
FALLBACK_SCRIPT="/root/brb_fallback.sh"
VIDEO="/root/stream-server-config/BRB_Australia_IRL_10s.mp4"
LOG_FILE="/var/log/moblin-brb.log"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

for required in "$RESTREAM" "$VIDEO"; do
  if [[ ! -f "$required" ]]; then
    echo "ERROR: required file not found: $required" >&2
    exit 1
  fi
done

mapfile -t DESTINATIONS < <(python3 - "$RESTREAM" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
urls = [value.strip("'\"") for value in re.findall(r'-f\s+flv\s+([^\s&]+)', text)]
unique = []
for url in urls:
    if url not in unique:
        unique.append(url)
if len(unique) != 3:
    raise SystemExit(f"ERROR: expected 3 RTMP destinations, found {len(unique)}")
for url in unique:
    print(url)
PY
)

if [[ ${#DESTINATIONS[@]} -ne 3 ]]; then
  echo "ERROR: could not extract exactly 3 streaming destinations." >&2
  exit 1
fi

BACKUP="${FALLBACK_SCRIPT}.backup-$(date +%Y%m%d-%H%M%S)"
if [[ -f "$FALLBACK_SCRIPT" ]]; then
  cp "$FALLBACK_SCRIPT" "$BACKUP"
fi

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
  -map '0:a:0?' \
  -c:v libx264 \
  -preset veryfast \
  -tune zerolatency \
  -profile:v high \
  -pix_fmt yuv420p \
  -r 30 \
  -g 60 \
  -keyint_min 60 \
  -sc_threshold 0 \
  -b:v 4500k \
  -maxrate 4500k \
  -bufsize 9000k \
  -c:a aac \
  -b:a 128k \
  -ar 48000 \
  -af aresample=async=1:first_pts=0 \
  -avoid_negative_ts make_zero \
  -flvflags no_duration_filesize \
  -f tee \
SCRIPT
  printf '  %q\n' "[f=flv:onfail=ignore]${DESTINATIONS[0]}|[f=flv:onfail=ignore]${DESTINATIONS[1]}|[f=flv:onfail=ignore]${DESTINATIONS[2]}"
} > "$FALLBACK_SCRIPT"

chmod 700 "$FALLBACK_SCRIPT"
bash -n "$FALLBACK_SCRIPT"

echo "BRB RTMP codec fix installed."
echo "BRB video will now be transcoded to H.264/AAC before publishing."
if [[ -f "$BACKUP" ]]; then
  echo "Backup: $BACKUP"
fi
