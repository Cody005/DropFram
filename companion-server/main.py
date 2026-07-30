"""Private DropFrame resolver.

Run this only on a trusted machine/network. It uses yt-dlp to inspect a page,
then exposes short-lived signed download tickets to the iPhone app.
"""

from __future__ import annotations

import asyncio
import ipaddress
import os
import shutil
import socket
import tempfile
from importlib.util import find_spec
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from yt_dlp.version import __version__ as yt_dlp_version
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from pydantic import BaseModel, HttpUrl

from media_pipeline import (
    download_video,
    extract_info,
    quality_groups,
    selectors_for_quality,
)

app = FastAPI(title="DropFrame Download Engine", version="2.0.0")

PRIVATE_TOKEN = os.environ.get("DROPFRAME_TOKEN", "")
SIGNING_SECRET = os.environ.get("DROPFRAME_SIGNING_SECRET") or PRIVATE_TOKEN or os.urandom(32).hex()
signer = URLSafeTimedSerializer(SIGNING_SECRET, salt="dropframe-download")


class ResolveBody(BaseModel):
    url: HttpUrl


def require_authorization(authorization: str | None) -> None:
    if not PRIVATE_TOKEN:
        return
    if authorization != f"Bearer {PRIVATE_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid DropFrame token")


def require_public_web_target(value: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise HTTPException(status_code=400, detail="Only HTTP(S) URLs are supported")

    try:
        addresses = socket.getaddrinfo(parsed.hostname, parsed.port or 443, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        raise HTTPException(status_code=400, detail="The host could not be resolved") from error

    for address in addresses:
        ip = ipaddress.ip_address(address[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
            raise HTTPException(status_code=400, detail="Private network targets are not accepted")


@app.get("/health")
async def health() -> dict[str, str | bool]:
    return {
        "status": "ok",
        "pipeline": app.version,
        "yt_dlp": yt_dlp_version,
        "ffmpeg": shutil.which("ffmpeg") is not None,
        "browser_impersonation": find_spec("curl_cffi") is not None,
    }


@app.post("/resolve")
async def resolve(
    body: ResolveBody,
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    require_authorization(authorization)
    target = str(body.url)
    require_public_web_target(target)

    try:
        info = await asyncio.to_thread(extract_info, target)
    except Exception as error:
        raise HTTPException(status_code=422, detail=f"Could not resolve media: {error}") from error

    candidates: list[dict[str, Any]] = []
    for height, items in quality_groups(info):
        preferred = items[-1]
        selectors = selectors_for_quality(height, items)
        ticket = signer.dumps(
            {
                "url": target,
                "height": height,
                "selectors": selectors,
            }
        )
        download_url = str(request.base_url).rstrip("/") + f"/download/{ticket}"
        candidates.append(
            {
                "id": f"height-{height}" if height else "best",
                "url": download_url,
                "label": f"{height}p" if height else "Best available",
                "height": height,
                "width": preferred.get("width"),
                "ext": "mp4",
                "filesize": preferred.get("filesize") or preferred.get("filesize_approx"),
                "isHLS": False,
                "hasAudio": True,
            }
        )

    candidates.sort(key=lambda item: item.get("height") or 0, reverse=True)
    if not candidates and info.get("url"):
        ticket = signer.dumps(
            {
                "url": target,
                "height": info.get("height"),
                "selectors": ["bv*+ba/b"],
            }
        )
        candidates.append(
            {
                "id": "best",
                "url": str(request.base_url).rstrip("/") + f"/download/{ticket}",
                "label": "Best",
                "height": info.get("height"),
                "width": info.get("width"),
                "ext": "mp4",
                "filesize": info.get("filesize") or info.get("filesize_approx"),
                "isHLS": False,
                "hasAudio": True,
            }
        )

    return {
        "title": info.get("title") or "Untitled video",
        "thumbnail": info.get("thumbnail"),
        "duration": info.get("duration"),
        "formats": candidates,
    }


@app.get("/download/{ticket}")
async def download(ticket: str, background_tasks: BackgroundTasks) -> FileResponse:
    try:
        payload = signer.loads(ticket, max_age=15 * 60)
    except SignatureExpired as error:
        raise HTTPException(status_code=410, detail="This download ticket expired") from error
    except BadSignature as error:
        raise HTTPException(status_code=400, detail="Invalid download ticket") from error

    require_public_web_target(payload["url"])
    directory = Path(tempfile.mkdtemp(prefix="dropframe-"))
    try:
        file_path = await asyncio.to_thread(download_video, payload, directory)
    except Exception as error:
        shutil.rmtree(directory, ignore_errors=True)
        raise HTTPException(status_code=422, detail=f"Could not prepare download: {error}") from error

    background_tasks.add_task(shutil.rmtree, directory, True)
    return FileResponse(
        file_path,
        filename=file_path.name,
        media_type="video/mp4",
        background=background_tasks,
    )
