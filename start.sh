#!/bin/sh
set -e

echo "[Slack Translator] Stopping containers and removing volumes..."
docker compose down -v

echo "[Slack Translator] Building and starting translator service..."
docker compose up --build translator
