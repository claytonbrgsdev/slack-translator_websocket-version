#!/bin/sh
set -e

# variável para container
CONTAINER_NAME=slack-translator
# parar container existente se estiver rodando
if docker ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
  echo "[Slack Translator] Parando container existente..."
  docker stop ${CONTAINER_NAME}
fi

echo "[Slack Translator] Building Docker image..."
docker build -t slack-translator:latest .

echo "[Slack Translator] Starting container..."
docker run --rm -it --name ${CONTAINER_NAME} -p 4567:4567 -e PORT=4567 --env-file .env slack-translator:latest
