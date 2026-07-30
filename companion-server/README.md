# DropFrame Download Engine

This private resolver gives the iPhone app broad site coverage through
`yt-dlp`. It groups every HLS, DASH, and progressive rendition belonging to a
quality behind one short-lived ticket. During download it tries those
renditions in preference order, merges separate video/audio tracks, and
validates the result with `ffprobe`.

H.264/AAC sources are remuxed without quality loss. WebM, VP9, Opus, AV1, and
other combinations that are not universally safe as local iPhone files are
converted to H.264/AAC MP4 with a fast-start index before transfer.

## Run

Use Python 3.11 or newer and install FFmpeg first. On macOS:

```bash
brew install ffmpeg
```

You can double-click `start.command` in Finder. It creates the private virtual
environment, installs or updates the resolver, creates a local token on first
run, and prints the exact URL/token to enter in DropFrame. If it reports that
Python or FFmpeg is missing, install them with:

```bash
brew install python@3.13 ffmpeg
```

Or run it manually:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --upgrade -r requirements.txt
export DROPFRAME_TOKEN="choose-a-private-token"
export DROPFRAME_SIGNING_SECRET="choose-a-long-random-secret"
uvicorn main:app --host 0.0.0.0 --port 8787
```

In DropFrame Settings, enter the computer's LAN address such as
`http://192.168.1.10:8787` and the same private token. DropFrame selects this
engine automatically when a webpage needs it.

Tap **Check download engine** in Settings. A working setup reports the installed
`yt-dlp` version, `Browser ready`, and `FFmpeg ready`.

The requirements include `curl_cffi`, which lets current extractors impersonate
a supported browser when a site checks the TLS/browser fingerprint. Keep
`yt-dlp` current because site extractors change frequently:

```bash
source .venv/bin/activate
python -m pip install --upgrade -r requirements.txt
```

Keep this service on a trusted network. Do not expose it publicly without TLS,
an authentication proxy, rate limits, and proper operational hardening.

Restart `start.command` after changing the engine source. A running Python
process keeps the previous pipeline code in memory.
