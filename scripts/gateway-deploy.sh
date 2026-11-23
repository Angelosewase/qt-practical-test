#!/usr/bin/env bash
# Installs the Gateway API bonus: pinned Standard CRDs, Traefik as the controller, then the Gateway and HTTPRoutes.
# Each step waits until the API server reports /readyz ok three times in a row, because etcd on this cluster stalls
# under write bursts (README "Known limitation"). Stops on the first failure.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT/k8s/gateway-api"
KUBECTL="${KUBECTL:-kubectl}"

calm() {
  local ok=0 tries=0
  while (( ok < 3 )); do
    if [[ "$($KUBECTL get --raw=/readyz --request-timeout=10s 2>/dev/null)" == ok ]]; then ok=$((ok + 1)); else ok=0; fi
    tries=$((tries + 1))
    (( tries > 60 )) && { echo "gateway-deploy: API server not stable, stopping" >&2; exit 1; }
    sleep 2
  done
  echo "gateway-deploy: /readyz ok x3"
}

echo "[1/5] verify vendored files"
sha256sum -c SHA256SUMS

echo "[2/5] Gateway API v1.6.3 Standard CRDs"
calm
$KUBECTL apply --server-side --force-conflicts -f crds/gateway-api-v1.6.3-standard-install.yaml
$KUBECTL wait --for=condition=Established --timeout=120s \
  crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io

echo "[3/5] Traefik v3.7.17 controller (namespace traefik-gateway, workers only, NodePort 30090)"
calm
$KUBECTL apply -k controller
$KUBECTL -n traefik-gateway rollout status deploy/traefik --timeout=300s

echo "[4/5] GatewayClass, Gateway and HTTPRoutes in qt-spring-app"
calm
$KUBECTL apply -f routes/gateway.yaml
$KUBECTL -n qt-spring-app wait --for=condition=Programmed gateway/projecthub --timeout=120s
$KUBECTL -n qt-spring-app wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
  httproute/projecthub-api httproute/projecthub-frontend --timeout=120s

echo "[5/5] state"
$KUBECTL get gatewayclass,gateway,httproute -A
$KUBECTL -n traefik-gateway get pods,svc -o wide
