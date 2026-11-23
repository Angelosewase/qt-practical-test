#!/usr/bin/env bash
# Removes the Gateway API bonus in reverse order: routes, controller, then the CRDs. The main deployment
# (nginx gateway on NodePort 30080) is not touched. The extra :30090 CORS origins are harmless and stay.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT/k8s/gateway-api"
KUBECTL="${KUBECTL:-kubectl}"
$KUBECTL delete -f routes/gateway.yaml --ignore-not-found --wait=true
$KUBECTL delete -k controller --ignore-not-found --wait=true
$KUBECTL delete -f crds/gateway-api-v1.6.3-standard-install.yaml --ignore-not-found --wait=true
echo "gateway-uninstall: done"
