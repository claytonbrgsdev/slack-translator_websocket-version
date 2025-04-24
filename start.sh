#!/bin/sh
set -e

echo "[Slack Translator] Building Docker image..."
docker build -t slack-translator:latest .

echo "[Slack Translator] Starting container..."
docker run --rm -it -p 4567:4567 --env-file .env slack-translator:latest
