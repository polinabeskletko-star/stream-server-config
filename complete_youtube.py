#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

TOKEN_FILE = Path("/root/youtube-token.json")
SCOPES = ["https://www.googleapis.com/auth/youtube"]


def load_credentials() -> Credentials:
    if not TOKEN_FILE.exists():
        raise FileNotFoundError(f"Token file not found: {TOKEN_FILE}")

    credentials = Credentials.from_authorized_user_file(
        str(TOKEN_FILE),
        SCOPES,
    )

    if credentials.expired and credentials.refresh_token:
        credentials.refresh(Request())
        TOKEN_FILE.write_text(credentials.to_json(), encoding="utf-8")
        TOKEN_FILE.chmod(0o600)

    if not credentials.valid:
        raise RuntimeError("YouTube OAuth credentials are not valid.")

    return credentials


def find_live_broadcasts(youtube: Any) -> list[dict[str, Any]]:
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

    return [
        item
        for item in response.get("items", [])
        if item.get("status", {}).get("lifeCycleStatus") == "live"
    ]


def main() -> int:
    credentials = load_credentials()
    youtube = build(
        "youtube",
        "v3",
        credentials=credentials,
        cache_discovery=False,
    )

    broadcasts = find_live_broadcasts(youtube)

    if not broadcasts:
        print("No live YouTube broadcast found. Nothing to complete.")
        return 0

    if len(broadcasts) > 1:
        print("More than one live broadcast was found; refusing to guess.")
        for broadcast in broadcasts:
            title = broadcast.get("snippet", {}).get("title", "Untitled")
            print(f"- {broadcast.get('id')}: {title}")
        return 2

    broadcast = broadcasts[0]
    broadcast_id = broadcast["id"]
    title = broadcast.get("snippet", {}).get("title", "Untitled")

    result = (
        youtube.liveBroadcasts()
        .transition(
            part="id,status",
            broadcastStatus="complete",
            id=broadcast_id,
        )
        .execute()
    )

    final_status = result.get("status", {}).get("lifeCycleStatus", "unknown")
    print(
        f"Completed YouTube broadcast {broadcast_id!r} "
        f"({title!r}); status={final_status}."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
    except HttpError as error:
        print(f"YouTube API error: {error}", file=sys.stderr)
        raise SystemExit(1)
    except json.JSONDecodeError as error:
        print(f"Invalid token JSON: {error}", file=sys.stderr)
        raise SystemExit(1)
