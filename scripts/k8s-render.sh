#!/usr/bin/env bash
# Renders k8s/ to stdout: fills in the Docker Hub user and image tags, skips the secret template.
# Image coordinates come from the environment if set, otherwise from docker/.env.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
ENV_FILE="$ROOT/docker/.env"

read_env() { [[ -f "$ENV_FILE" ]] && grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true; }
DOCKERHUB_USER="${DOCKERHUB_USER:-$(read_env DOCKERHUB_USER)}"
API_TAG="${API_TAG:-$(read_env API_TAG)}"
FRONTEND_TAG="${FRONTEND_TAG:-$(read_env FRONTEND_TAG)}"

for v in DOCKERHUB_USER API_TAG FRONTEND_TAG; do
  if [[ -z "${!v}" || "${!v}" == *"<"* ]]; then
    echo "k8s-render: $v is not set (docker/.env or environment)" >&2
    exit 1
  fi
done

first=1
for f in "$ROOT"/k8s/*.yaml; do
  [[ "$(basename "$f")" == secret.example.yaml ]] && continue
  if [[ $first -eq 0 ]]; then echo "---"; fi
  first=0
  sed -e "s#__DOCKERHUB_USER__#${DOCKERHUB_USER}#g" \
      -e "s#__API_TAG__#${API_TAG}#g" \
      -e "s#__FRONTEND_TAG__#${FRONTEND_TAG}#g" "$f"
done
