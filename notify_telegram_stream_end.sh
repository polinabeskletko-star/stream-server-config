#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/root/telegram-webhook.env"
ENDPOINT="https://fts-panda-telegram-bot.fly.dev/stream/end"
STATE_DIR="/var/lib/fts-panda"
STATE_FILE="$STATE_DIR/live-message-id"

if [[ ! -s "$STATE_FILE" ]]; then
  echo "No tracked Telegram announcement to delete."
  exit 0
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Telegram secret file missing." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${STREAM_WEBHOOK_KEY:?STREAM_WEBHOOK_KEY not set}"

exec 9>"$STATE_DIR/notification.lock"
flock -x 9
if [[ ! -s "$STATE_FILE" ]]; then exit 0; fi
read -r message_id < "$STATE_FILE"
if ! [[ "$message_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: Invalid saved message ID, refusing deletion." >&2
  exit 1
fi

payload=$(python3 -c 'import json,sys; print(json.dumps({"telegram_message_id": int(sys.argv[1])}))' "$message_id")
response=$(curl --fail-with-body -sS --connect-timeout 5 --max-time 25 \
  -X POST "$ENDPOINT" -H "X-API-Key: $STREAM_WEBHOOK_KEY" \
  -H "Content-Type: application/json" --data "$payload")

status=$(printf '%s' "$response" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))')
if [[ "$status" == "deleted" ]]; then
  rm -f "$STATE_FILE"
  echo "Telegram announcement deleted."
else
  echo "ERROR: Telegram deletion was not confirmed: $response" >&2
  exit 1
fi
