from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

import yt_dlp


KNOWN_HEIGHTS = (4320, 2160, 1440, 1080, 720, 576, 540, 480, 360, 240, 144)
MEDIA_SUFFIXES = {".mp4", ".m4v", ".mov", ".webm", ".mkv", ".ts", ".flv"}


def extract_info(target: str) -> dict[str, Any]:
    options = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "skip_download": True,
        "noplaylist": True,
        "socket_timeout": 30,
    }
    with yt_dlp.YoutubeDL(options) as downloader:
        result = downloader.extract_info(target, download=False)
        if result.get("_type") == "playlist":
            entries = [entry for entry in result.get("entries", []) if entry]
            if not entries:
                raise ValueError("No video found")
            return entries[0]
        return result


def format_height(item: dict[str, Any]) -> int | None:
    height = item.get("height")
    if isinstance(height, (int, float)) and height > 0:
        return int(height)

    searchable = " ".join(
        str(item.get(key) or "")
        for key in ("format_id", "format_note", "resolution", "format")
    )
    dimension = re.search(
        r"(?<!\d)\d{2,5}\s*x\s*(\d{3,4})(?!\d)",
        searchable,
        re.IGNORECASE,
    )
    if dimension:
        return int(dimension.group(1))

    for known_height in KNOWN_HEIGHTS:
        if re.search(
            rf"(?<!\d){known_height}\s*p?(?!\d)",
            searchable,
            re.IGNORECASE,
        ):
            return known_height

    normalized = searchable.upper()
    aliases = (
        (2160, (r"\b4K\b", r"\bUHD\b", r"\bULTRA HD\b")),
        (1440, (r"\b2K\b", r"\bQHD\b")),
        (1080, (r"\bFHD\b", r"\bFULL HD\b")),
        (720, (r"\bHD\b",)),
    )
    for height_alias, patterns in aliases:
        if any(re.search(pattern, normalized) for pattern in patterns):
            return height_alias
    return None


def quality_groups(info: dict[str, Any]) -> list[tuple[int | None, list[dict[str, Any]]]]:
    """Group every usable rendition by height without exposing host URLs."""
    grouped: dict[int | None, list[dict[str, Any]]] = {}
    for item in info.get("formats") or []:
        if (
            not item.get("url")
            or item.get("vcodec") == "none"
            or item.get("has_drm")
        ):
            continue

        format_id = str(item.get("format_id") or "")
        if not format_id:
            continue
        grouped.setdefault(format_height(item), []).append(item)

    if any(height for height in grouped):
        grouped.pop(None, None)

    return sorted(
        grouped.items(),
        key=lambda entry: entry[0] or 0,
        reverse=True,
    )


def exact_format_selector(item: dict[str, Any]) -> str:
    format_id = str(item["format_id"])
    if item.get("acodec") != "none":
        return format_id
    return f"{format_id}+bestaudio/{format_id}"


def selectors_for_quality(height: int | None, items: list[dict[str, Any]]) -> list[str]:
    selectors: list[str] = []
    seen_format_ids: set[str] = set()

    # yt-dlp lists formats from lower to higher preference. Try its preferred
    # rendition first, while retaining alternate transports for the resolution.
    for item in reversed(items):
        format_id = str(item.get("format_id") or "")
        if not format_id or format_id in seen_format_ids:
            continue
        seen_format_ids.add(format_id)
        selectors.append(exact_format_selector(item))

    if height:
        selectors.append(f"bv*[height={height}]+ba/b[height={height}]")
    else:
        selectors.append("bv*+ba/b")
    return list(dict.fromkeys(selectors))


def probe_video(file_path: Path) -> dict[str, Any]:
    if file_path.stat().st_size < 4_096:
        raise RuntimeError("The selected quality returned an empty media file")

    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=index,codec_type,codec_name,width,height:format=format_name,duration",
            "-of",
            "json",
            str(file_path),
        ],
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError("The selected quality did not produce a valid video")

    try:
        probe = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("The selected quality could not be verified") from error

    video_streams = [
        stream
        for stream in probe.get("streams") or []
        if stream.get("codec_type") == "video"
    ]
    if not video_streams or not video_streams[0].get("codec_name"):
        raise RuntimeError("The selected quality did not contain a video track")
    return probe


def validate_video(file_path: Path) -> None:
    probe_video(file_path)


def run_ffmpeg(arguments: list[str]) -> None:
    result = subprocess.run(
        ["ffmpeg", "-y", "-v", "error", *arguments],
        capture_output=True,
        check=False,
        text=True,
        timeout=7_200,
    )
    if result.returncode != 0:
        detail = result.stderr.strip().splitlines()
        raise RuntimeError(
            detail[-1] if detail else "FFmpeg could not prepare the video"
        )


def normalize_for_iphone(source: Path, destination: Path) -> Path:
    probe = probe_video(source)
    streams = probe.get("streams") or []
    video = next(stream for stream in streams if stream.get("codec_type") == "video")
    audio = next(
        (stream for stream in streams if stream.get("codec_type") == "audio"),
        None,
    )
    can_remux = (
        video.get("codec_name") == "h264"
        and (audio is None or audio.get("codec_name") in {"aac", "mp3", "alac"})
    )

    destination.unlink(missing_ok=True)
    if can_remux:
        try:
            run_ffmpeg(
                [
                    "-i",
                    str(source),
                    "-map",
                    "0:v:0",
                    "-map",
                    "0:a:0?",
                    "-c",
                    "copy",
                    "-movflags",
                    "+faststart",
                    str(destination),
                ]
            )
            validate_video(destination)
            return destination
        except RuntimeError:
            destination.unlink(missing_ok=True)

    run_ffmpeg(
        [
            "-i",
            str(source),
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "21",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-movflags",
            "+faststart",
            str(destination),
        ]
    )
    validate_video(destination)
    return destination


def download_attempt(target: str, selector: str, directory: Path) -> Path:
    options = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "noplaylist": True,
        "format": selector,
        "outtmpl": str(directory / "source-%(id)s.%(ext)s"),
        "merge_output_format": "mkv",
        "socket_timeout": 30,
        "concurrent_fragment_downloads": 4,
        "retries": 5,
        "fragment_retries": 5,
        "check_formats": "selected",
    }
    with yt_dlp.YoutubeDL(options) as downloader:
        downloader.extract_info(target, download=True)

    files = sorted(
        (
            item
            for item in directory.iterdir()
            if item.is_file() and item.suffix.lower() in MEDIA_SUFFIXES
        ),
        key=lambda item: item.stat().st_size,
        reverse=True,
    )
    for file_path in files:
        try:
            validate_video(file_path)
            return file_path
        except RuntimeError:
            continue
    raise RuntimeError("yt-dlp did not create a valid video stream")


def download_video(payload: dict[str, Any], directory: Path) -> Path:
    selectors = payload.get("selectors") or []
    if not selectors:
        legacy_selector = payload.get("format_selector") or payload.get("format_id")
        if legacy_selector:
            selectors = [legacy_selector]
    if not selectors:
        selectors = ["bv*+ba/b"]

    errors: list[str] = []
    for index, selector in enumerate(selectors):
        attempt_directory = directory / f"attempt-{index}"
        attempt_directory.mkdir()
        try:
            source = download_attempt(payload["url"], str(selector), attempt_directory)
            return normalize_for_iphone(source, directory / "DropFrame-video.mp4")
        except Exception as error:
            errors.append(f"{selector}: {error}")
            shutil.rmtree(attempt_directory, ignore_errors=True)

    summary = " | ".join(errors[-3:])
    raise RuntimeError(f"No rendition for this quality could be prepared. {summary}")
