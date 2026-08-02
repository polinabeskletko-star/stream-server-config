#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/mediamtx.yml"
HOOK="/root/complete_youtube_on_stop.sh"
PYTHON="/root/youtube-venv/bin/python"
COMPLETE_SCRIPT="/root/complete_youtube.py"
LOG="/var/log/youtube-complete.log"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mediamtx.yml.backup-youtube-hook-${STAMP}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root." >&2
  exit 1
fi

for required in "$CONFIG" "$PYTHON" "$COMPLETE_SCRIPT" "/root/youtube-token.json"; do
  if [[ ! -e "$required" ]]; then
    echo "ERROR: required file was not found: $required" >&2
    exit 1
  fi
done

cp "$CONFIG" "$BACKUP"

cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
set -u

# Give YouTube a moment to register that the encoder connection has closed.
sleep 3

/root/youtube-venv/bin/python /root/complete_youtube.py \
  >> /var/log/youtube-complete.log 2>&1 || true
EOF
chmod 700 "$HOOK"

python3 - "$CONFIG" "$HOOK" <<'PY'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
hook_path = Path(sys.argv[2])
text = config_path.read_text(encoding="utf-8")

pattern = re.compile(
    r"(?m)^(?P<indent>\s*)runOnReady:\s*/root/restream\.sh\s*$"
    r"\n(?P=indent)runOnReadyRestart:\s*true\s*$"
    r"(?:\n(?P=indent)runOnNotReady:\s*.*$)?"
)
match = pattern.search(text)
if not match:
    raise SystemExit(
        "ERROR: could not find the /root/restream.sh runOnReady block. "
        "No MediaMTX configuration changes were applied."
    )

indent = match.group("indent")
replacement = (
    f"{indent}runOnReady: /root/restream.sh\n"
    f"{indent}runOnReadyRestart: true\n"
    f"{indent}runOnNotReady: {hook_path}"
)

config_path.write_text(
    pattern.sub(replacement, text, count=1),
    encoding="utf-8",
)
PY

systemctl restart mediamtx
systemctl --no-pager --full status mediamtx

echo
echo "YouTube completion hook installed."
echo "When the Moblin input stops, MediaMTX will run: $HOOK"
echo "Hook log: $LOG"
echo "Rollback: cp '$BACKUP' '$CONFIG' && systemctl restart mediamtx"
