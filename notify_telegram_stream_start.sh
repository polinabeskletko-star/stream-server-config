#!/usr/bin/env bash
set -u

ENV_FILE="/root/telegram-webhook.env"
ENDPOINT="https://fts-panda-telegram-bot.fly.dev/stream/start"
STATE_FILE="/tmp/fts-panda-telegram-last-notify"
COOLDOWN_SECONDS="${STREAM_NOTIFICATION_COOLDOWN_SECONDS:-120}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Telegram notify skipped: $ENV_FILE not found"
  exit 0
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ -z "${STREAM_WEBHOOK_KEY:-}" ]]; then
  echo "Telegram notify skipped: STREAM_WEBHOOK_KEY is not set in $ENV_FILE"
  exit 0
fi

now=$(date +%s)
last=0
if [[ -f "$STATE_FILE" ]]; then
  read -r last < "$STATE_FILE" || last=0
fi

if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < COOLDOWN_SECONDS )); then
  echo "Telegram notify skipped: cooldown (${COOLDOWN_SECONDS}s)"
  exit 0
fi

response=$(curl -fsS \
  --connect-timeout 5 \
  --max-time 15 \
  -X POST "$ENDPOINT" \
  -H "X-API-Key: $STREAM_WEBHOOK_KEY" \
  -H "Content-Type: application/json" \
  --data '{}') || {
    echo "Telegram notify failed"
    exit 1
  }

printf '%s\n' "$now" > "$STATE_FILE"
echo "Telegram notify response: $response"
