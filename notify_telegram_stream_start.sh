#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/root/telegram-webhook.env"
ENDPOINT="https://fts-panda-telegram-bot.fly.dev/stream/start"
STATE_DIR="/var/lib/fts-panda"
STATE_FILE="$STATE_DIR/live-message-id"
COOLDOWN_FILE="$STATE_DIR/last-notify"
COOLDOWN_SECONDS="${STREAM_NOTIFICATION_COOLDOWN_SECONDS:-120}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Telegram notification skipped: $ENV_FILE missing" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${STREAM_WEBHOOK_KEY:?STREAM_WEBHOOK_KEY not set}"

install -d -m 700 "$STATE_DIR"
exec 9>"$STATE_DIR/notification.lock"
flock -x 9

if [[ -s "$STATE_FILE" ]]; then
  echo "Telegram announcement already tracked; no duplicate created."
  exit 0
fi

now=$(date +%s)
last=0
if [[ -f "$COOLDOWN_FILE" ]]; then read -r last < "$COOLDOWN_FILE" || true; fi
if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < COOLDOWN_SECONDS )); then
  echo "Telegram notification skipped: cooldown"
  exit 0
fi

response=$(curl --fail-with-body -sS --connect-timeout 5 --max-time 35 \
  -X POST "$ENDPOINT" -H "X-API-Key: $STREAM_WEBHOOK_KEY" \
  -H "Content-Type: application/json" --data '{}')

message_id=$(printf '%s' "$response" | python3 -c '
import json,sys
r=json.load(sys.stdin)
v=r.get("telegram_message_id") if r.get("status")=="sent" else None
if type(v) is int and v>0: print(v)
')
if [[ -n "$message_id" ]]; then
  printf '%s\n' "$message_id" > "$STATE_FILE.tmp"
  chmod 600 "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  printf '%s\n' "$now" > "$COOLDOWN_FILE"
  echo "Telegram notification sent and message ID saved."
else
  echo "No new notification sent: $response" >&2
fi
