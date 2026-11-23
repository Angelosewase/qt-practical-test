#!/usr/bin/env bash
# Creates or updates the app-secrets Secret from docker/.env. Values are read from a temporary file that
# is removed on exit. They are never printed and never written into the repository.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
ENV_FILE="$ROOT/docker/.env"
NS="${K8S_NAMESPACE:-qt-spring-app}"   # make helm-deploy sets qt-spring-app-helm
KUBECTL="${KUBECTL:-kubectl}"

[[ -f "$ENV_FILE" ]] || { echo "k8s-secrets: docker/.env missing (run: make env)" >&2; exit 1; }

TMP="$(mktemp "$ROOT/.tmp/k8s-secret.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
grep -E '^(MONGO_ROOT_USER|MONGO_ROOT_PASSWORD|VALKEY_PASSWORD|JWT_SECRET)=' "$ENV_FILE" >"$TMP"

if [[ "$(wc -l <"$TMP")" -ne 4 ]]; then
  echo "k8s-secrets: docker/.env must define MONGO_ROOT_USER, MONGO_ROOT_PASSWORD, VALKEY_PASSWORD and JWT_SECRET" >&2
  exit 1
fi
if grep -q 'change-me' "$TMP"; then
  echo "k8s-secrets: refusing to deploy placeholder values (run: make env)" >&2
  exit 1
fi

$KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create secret generic app-secrets --from-env-file="$TMP" --dry-run=client -o yaml | $KUBECTL apply -f -
echo "k8s-secrets: app-secrets applied to namespace $NS (values not shown)"
