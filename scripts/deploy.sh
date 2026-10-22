#!/usr/bin/env bash
# Runs ON the web server (invoked by Jenkins over SSH).
# Pulls a Docker image from Docker Hub and runs it as the "webapp" container.
# Usage: deploy.sh <image:tag>      e.g. deploy.sh myuser/proj5-webapp:12-ab12cd3
set -euo pipefail

IMAGE="${1:?usage: deploy.sh <image:tag>}"
NAME=webapp
ENV_FILE=/etc/webapp.env

start_container() {
  sudo docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -p 127.0.0.1:8000:8000 \
    "$1" >/dev/null
}

is_healthy() {
  for _ in $(seq 1 15); do
    if curl -fsS http://127.0.0.1:8000/health >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

sudo docker pull "$IMAGE"

# Remember what is running now so we can roll back.
PREVIOUS=""
if sudo docker inspect "$NAME" >/dev/null 2>&1; then
  PREVIOUS="$(sudo docker inspect --format '{{.Config.Image}}' "$NAME")"
  sudo docker rm -f "$NAME" >/dev/null
fi

start_container "$IMAGE"

if ! is_healthy; then
  echo "Health check failed for $IMAGE" >&2
  sudo docker logs --tail 30 "$NAME" >&2 || true
  sudo docker rm -f "$NAME" >/dev/null || true
  if [ -n "$PREVIOUS" ]; then
    echo "Rolling back to $PREVIOUS" >&2
    start_container "$PREVIOUS"
  fi
  exit 1
fi

# Remove unused images older than 7 days (the previous release is kept for rollback).
sudo docker image prune -af --filter "until=168h" >/dev/null || true
echo "Deployed $IMAGE"
