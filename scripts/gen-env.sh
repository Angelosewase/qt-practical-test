#!/usr/bin/env bash
# Creates docker/.env from docker/.env.example with freshly generated secrets.
# Existing values are kept: the script never overwrites a real .env. Secrets are never printed.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
TARGET="$ROOT/docker/.env"
EXAMPLE="$ROOT/docker/.env.example"

if [[ -f "$TARGET" ]]; then
  echo "gen-env: $TARGET already exists, leaving it unchanged"
  exit 0
fi

umask 077
secret() { openssl rand -hex "$1"; }
sed \
  -e "s/^MONGO_ROOT_PASSWORD=.*/MONGO_ROOT_PASSWORD=$(secret 24)/" \
  -e "s/^VALKEY_PASSWORD=.*/VALKEY_PASSWORD=$(secret 24)/" \
  -e "s/^JWT_SECRET=.*/JWT_SECRET=$(secret 32)/" \
  -e "s/^DOCKERHUB_USER=.*/DOCKERHUB_USER=${DOCKERHUB_USER:-your-dockerhub-username}/" \
  "$EXAMPLE" >"$TARGET"
chmod 600 "$TARGET"
echo "gen-env: created $TARGET (chmod 600) with generated secrets"
