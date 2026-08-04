import json
import traceback


def _text(value):
    return str(value or "").strip()


def _lower(value):
    return _text(value).lower()


def _number(value, fallback=0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def _string_headers(value):
    if not isinstance(value, dict):
        return None
    headers = {
        str(key): str(item)
        for key, item in value.items()
        if key is not None and item is not None
    }
    return headers or None


def _is_http(item):
    return _lower(item.get("protocol")) in ("http", "https")


def _has_video(item):
    codec = _lower(item.get("vcodec"))
    return bool(codec) and codec != "none"


def _has_audio(item):
    codec = _lower(item.get("acodec"))
    return bool(codec) and codec != "none"


def _is_iphone_video(item):
    codec = _lower(item.get("vcodec"))
    return (
        _lower(item.get("ext")) == "mp4"
        and _is_http(item)
        and _has_video(item)
        and (
            codec.startswith("avc1")
            or codec.startswith("avc3")
            or codec.startswith("h264")
        )
    )


def _is_iphone_audio(item):
    codec = _lower(item.get("acodec"))
    return (
        _lower(item.get("ext")) in ("m4a", "mp4")
        and _is_http(item)
        and _has_audio(item)
        and not _has_video(item)
        and (codec.startswith("mp4a") or codec.startswith("aac"))
    )


def _filesize(item):
    value = item.get("filesize") or item.get("filesize_approx")
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _video_score(item):
    return (
        _number(item.get("height"), -1),
        _number(item.get("fps"), -1),
        _number(item.get("quality"), -1),
        _number(item.get("tbr"), -1),
        _number(item.get("filesize") or item.get("filesize_approx"), -1),
    )


def _audio_score(item):
    # yt-dlp's language_preference/preference values keep the extractor's
    # intended default audio ahead of alternate or descriptive tracks.
    return (
        _number(item.get("language_preference"), -1),
        _number(item.get("preference"), -1),
        _number(item.get("quality"), -1),
        _number(item.get("abr"), -1),
        _number(item.get("tbr"), -1),
        _number(item.get("asr"), -1),
    )


def _payload(video, audio=None):
    video_size = _filesize(video)
    audio_size = _filesize(audio) if audio else None
    total_size = None
    if video_size is not None or audio_size is not None:
        total_size = (video_size or 0) + (audio_size or 0)

    video_id = _text(video.get("format_id"))
    audio_id = _text(audio.get("format_id")) if audio else ""
    selection_id = video_id if not audio_id else f"{video_id}+{audio_id}"

    return {
        "id": selection_id,
        "url": _text(video.get("url")),
        "audio_url": _text(audio.get("url")) if audio else None,
        "extension": "mp4",
        "width": video.get("width"),
        "height": video.get("height"),
        "filesize": total_size,
        "video_filesize": video_size,
        "audio_filesize": audio_size,
        "video_headers": _string_headers(video.get("http_headers")),
        "audio_headers": _string_headers(audio.get("http_headers")) if audio else None,
        "needs_muxing": audio is not None,
    }


def _build_formats(info):
    source_formats = info.get("formats") or []
    audio_candidates = [item for item in source_formats if _is_iphone_audio(item)]
    best_audio = max(audio_candidates, key=_audio_score, default=None)

    # Keep one best iPhone-playable option per displayed height. A native MP4
    # that already contains audio wins at the same height; otherwise pair the
    # best H.264 MP4 video track with the preferred AAC/M4A audio track.
    choices_by_height = {}
    for item in source_formats:
        if not _is_iphone_video(item):
            continue

        height = item.get("height")
        try:
            height_key = int(height) if height is not None else 0
        except (TypeError, ValueError):
            height_key = 0

        contains_audio = _has_audio(item)
        if not contains_audio and best_audio is None:
            continue

        candidate = _payload(item, None if contains_audio else best_audio)
        rank = (
            1 if contains_audio else 0,
            *_video_score(item),
        )
        previous = choices_by_height.get(height_key)
        if previous is None or rank > previous[0]:
            choices_by_height[height_key] = (rank, candidate)

    return [
        entry[1]
        for _, entry in sorted(
            choices_by_height.items(),
            key=lambda pair: pair[0],
            reverse=True,
        )
    ]


def resolve(download_url):
    try:
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

        formats = _build_formats(info)
        return json.dumps(
            {
                "success": bool(formats),
                "title": _text(info.get("title")),
                "thumbnail": info.get("thumbnail"),
                "duration": info.get("duration"),
                "formats": formats,
                "error_message": None
                if formats
                else (
                    "YouTube did not expose an iPhone-compatible H.264 video "
                    "with AAC audio for this link."
                ),
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
