#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"

if command -v python3.13 >/dev/null 2>&1; then
    python_command="$(command -v python3.13)"
elif command -v python3.12 >/dev/null 2>&1; then
    python_command="$(command -v python3.12)"
elif command -v python3.11 >/dev/null 2>&1; then
    python_command="$(command -v python3.11)"
else
    echo "DropFrame needs Python 3.11 or newer."
    echo "Install it with: brew install python@3.13"
    read -r "?Press Return to close."
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    echo "DropFrame needs FFmpeg to merge qualities and create iPhone-compatible MP4 files."
    echo "Install it with: brew install ffmpeg"
    read -r "?Press Return to close."
    exit 1
fi

if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "libx264"; then
    echo "This FFmpeg build cannot create universal iPhone H.264 files."
    echo "Install the Homebrew FFmpeg build with: brew install ffmpeg"
    read -r "?Press Return to close."
    exit 1
fi

if [[ ! -d .venv ]]; then
    "$python_command" -m venv .venv
fi

.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet --upgrade -r requirements.txt

if [[ ! -f .env ]]; then
    {
        echo "export DROPFRAME_TOKEN=$(openssl rand -hex 16)"
        echo "export DROPFRAME_SIGNING_SECRET=$(openssl rand -hex 32)"
    } > .env
    chmod 600 .env
fi

source .env

lan_address="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [[ -z "$lan_address" ]]; then
    lan_address="YOUR-MAC-IP"
fi

echo
echo "DropFrame Download Engine is ready."
echo "Engine address: http://${lan_address}:8787"
echo "Private token: ${DROPFRAME_TOKEN}"
echo "Keep this window open while resolving or downloading."
echo

exec .venv/bin/uvicorn main:app --host 0.0.0.0 --port 8787
