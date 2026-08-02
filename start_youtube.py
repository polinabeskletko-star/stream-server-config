#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

TOKEN_FILE = Path("/root/youtube-token.json")
STATE_FILE = Path("/root/youtube-current-broadcast.json")
SCOPES = ["https://www.googleapis.com/auth/youtube"]

STREAM_ID = os.environ.get(
    "YOUTUBE_STREAM_ID",
    "tn7_OWlxabdONpuBtxHgvw1785139458141013",
)
TITLE = os.environ.get("YOUTUBE_BROADCAST_TITLE", "Австралия в эфире.")
PRIVACY = os.environ.get("YOUTUBE_BROADCAST_PRIVACY", "public")
WAIT_SECONDS = int(os.environ.get("YOUTUBE_STREAM_WAIT_SECONDS", "180"))


def load_credentials() -> Credentials:
    if not TOKEN_FILE.exists():
        raise FileNotFoundError(f"Token file not found: {TOKEN_FILE}")

    credentials = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)

    if credentials.expired and credentials.refresh_token:
        credentials.refresh(Request())
        TOKEN_FILE.write_text(credentials.to_json(), encoding="utf-8")
        TOKEN_FILE.chmod(0o600)

    if not credentials.valid:
        raise RuntimeError("YouTube OAuth credentials are not valid.")

    return credentials


def get_broadcasts(youtube) -> list[dict]:
    response = (
        youtube.liveBroadcasts()
        .list(
            part="id,snippet,status,contentDetails",
            broadcastStatus="all",
            broadcastType="all",
            maxResults=50,
        )
        .execute()
    )
    return response.get("items", [])


def find_reusable_broadcast(youtube) -> dict | None:
    candidates = []
    for item in get_broadcasts(youtube):
        lifecycle = item.get("status", {}).get("lifeCycleStatus")
        bound_stream = item.get("contentDetails", {}).get("boundStreamId")
        if bound_stream == STREAM_ID and lifecycle in {
            "created",
            "ready",
            "testing",
            "testStarting",
            "liveStarting",
            "live",
        }:
            candidates.append(item)

    if not candidates:
        return None

    candidates.sort(
        key=lambda item: item.get("snippet", {}).get("scheduledStartTime", ""),
        reverse=True,
    )
    return candidates[0]


def create_and_bind_broadcast(youtube) -> dict:
    scheduled_start = datetime.now(timezone.utc) + timedelta(minutes=1)

    body = {
        "snippet": {
            "title": TITLE,
            "scheduledStartTime": scheduled_start.isoformat().replace("+00:00", "Z"),
        },
        "status": {
            "privacyStatus": PRIVACY,
            "selfDeclaredMadeForKids": False,
        },
        "contentDetails": {
            "monitorStream": {
                "enableMonitorStream": False,
                "broadcastStreamDelayMs": 0,
            },
            "enableAutoStart": False,
            "enableAutoStop": False,
            "enableDvr": True,
            "recordFromStart": True,
            "latencyPreference": "low",
        },
    }

    broadcast = (
        youtube.liveBroadcasts()
        .insert(part="snippet,status,contentDetails", body=body)
        .execute()
    )

    broadcast_id = broadcast["id"]

    broadcast = (
        youtube.liveBroadcasts()
        .bind(
            part="id,snippet,status,contentDetails",
            id=broadcast_id,
            streamId=STREAM_ID,
        )
        .execute()
    )

    print(f"Created and bound YouTube broadcast {broadcast_id!r} ({TITLE!r}).")
    return broadcast


def stream_status(youtube) -> str:
    response = (
        youtube.liveStreams()
        .list(part="id,status,snippet", id=STREAM_ID, maxResults=1)
        .execute()
    )
    items = response.get("items", [])
    if not items:
        raise RuntimeError(f"YouTube stream not found: {STREAM_ID}")
    return items[0].get("status", {}).get("streamStatus", "unknown")


def save_state(broadcast: dict) -> None:
    payload = {
        "id": broadcast["id"],
        "title": broadcast.get("snippet", {}).get("title", TITLE),
        "streamId": STREAM_ID,
        "savedAt": datetime.now(timezone.utc).isoformat(),
    }
    STATE_FILE.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    STATE_FILE.chmod(0o600)


def main() -> int:
    credentials = load_credentials()
    youtube = build("youtube", "v3", credentials=credentials, cache_discovery=False)

    broadcast = find_reusable_broadcast(youtube)
    if broadcast is None:
        broadcast = create_and_bind_broadcast(youtube)
    else:
        print(
            f"Using existing YouTube broadcast {broadcast['id']!r} "
            f"with status={broadcast.get('status', {}).get('lifeCycleStatus')}."
        )

    lifecycle = broadcast.get("status", {}).get("lifeCycleStatus")
    if lifecycle == "live":
        save_state(broadcast)
        print("YouTube broadcast is already live.")
        return 0

    deadline = time.monotonic() + WAIT_SECONDS
    last_status = None

    while time.monotonic() < deadline:
        current = stream_status(youtube)
        if current != last_status:
            print(f"YouTube stream status: {current}")
            last_status = current

        if current == "active":
            break

        time.sleep(3)
    else:
        raise RuntimeError(
            f"YouTube stream did not become active within {WAIT_SECONDS} seconds."
        )

    result = (
        youtube.liveBroadcasts()
        .transition(
            part="id,snippet,status,contentDetails",
            broadcastStatus="live",
            id=broadcast["id"],
        )
        .execute()
    )

    save_state(result)
    final_status = result.get("status", {}).get("lifeCycleStatus", "unknown")
    print(
        f"Started YouTube broadcast {result['id']!r} "
        f"({result.get('snippet', {}).get('title', TITLE)!r}); status={final_status}."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
    except HttpError as error:
        print(f"YouTube API error: {error}", file=sys.stderr)
        raise SystemExit(1)
