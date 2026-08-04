import json
import traceback
from urllib.parse import urlparse


def _string_headers(value):
    if not isinstance(value, dict):
        return None
    headers = {
        str(key): str(item)
        for key, item in value.items()
        if key is not None and item is not None
    }
    return headers or None


def _is_youtube_url(value):
    hostname = (urlparse(str(value).strip()).hostname or "").lower()
    return (
        hostname == "youtu.be"
        or hostname == "youtube.com"
        or hostname.endswith(".youtube.com")
        or hostname == "youtube-nocookie.com"
        or hostname.endswith(".youtube-nocookie.com")
    )


def resolve(download_url):
    try:
        if _is_youtube_url(download_url):
            from dropframe_youtube import resolve as resolve_youtube

            return resolve_youtube(download_url)

        import yt_dlp

        options = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "noplaylist": True,
            "cachedir": False,
        }
        with yt_dlp.YoutubeDL(options) as downloader:
            info = downloader.extract_info(str(download_url).strip(), download=False)
            info = downloader.sanitize_info(info)

        formats = []
        seen_media_urls = set()
        for item in info.get("formats") or []:
            media_url = str(item.get("url") or "").strip()
            format_id = str(item.get("format_id") or "").strip()
            protocol = str(item.get("protocol") or "").strip().lower()
            extension = str(item.get("ext") or "").strip().lower()
            video_codec = str(item.get("vcodec") or "").strip().lower()
            audio_codec = str(item.get("acodec") or "").strip().lower()
            # Some extractors (notably Instagram) expose a complete direct MP4
            # while leaving both codec fields unset. Keep that progressive file,
            # but never reinterpret HLS/DASH fragments or an explicit audio-only
            # format as a downloadable video.
            is_progressive_mp4 = (
                extension in ("mp4", "m4v", "mov")
                and protocol in ("http", "https")
            )
            has_video = video_codec != "none" and (
                bool(video_codec) or is_progressive_mp4
            )
            if (
                not media_url
                or not format_id
                or not has_video
                or media_url in seen_media_urls
            ):
                continue

            seen_media_urls.add(media_url)

            formats.append(
                {
                    "id": format_id,
                    "url": media_url,
                    "protocol": protocol,
                    "extension": extension,
                    "resolution": str(item.get("resolution") or "").strip(),
                    "format_note": str(item.get("format_note") or "").strip(),
                    "width": item.get("width"),
                    "height": item.get("height"),
                    "filesize": item.get("filesize")
                    or item.get("filesize_approx"),
                    # yt-dlp uses "none" for a confirmed video-only stream.
                    # A missing codec is unknown and many progressive MP4
                    # extractors leave it unset even though audio is present.
                    "has_audio": audio_codec != "none",
                    "http_headers": _string_headers(item.get("http_headers")),
                }
            )

        return json.dumps(
            {
                "success": bool(formats),
                "title": str(info.get("title") or "").strip(),
                "thumbnail": info.get("thumbnail"),
                "duration": info.get("duration"),
                "formats": formats,
                "error_message": None if formats else "yt-dlp found no usable video formats.",
            }
        )
    except BaseException as error:
        return json.dumps(
            {
                "success": False,
                "title": "",
                "thumbnail": None,
                "duration": None,
                "formats": [],
                "error_message": str(error),
                "traceback": traceback.format_exc(),
            }
        )
