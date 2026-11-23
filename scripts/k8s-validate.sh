#!/usr/bin/env bash
# Validates the Kubernetes manifests in four layers. Any failure stops the run.
#   1. render: placeholders filled from docker/.env
#   2. policy: requests/limits, probes, pinned tags, namespace, NodePort 30080
#   3. schema: kubeconform in strict mode against Kubernetes 1.32.5 (works offline once schemas are cached)
#   4. cluster: kubectl apply --dry-run=client and --dry-run=server, only if KUBECONFIG reaches a cluster
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
OUT="$ROOT/.tmp/k8s-rendered.yaml"
K8S_VERSION="${K8S_VERSION:-1.32.5}"

echo "[1/4] render"
scripts/k8s-render.sh >"$OUT"
echo "      $(grep -c '^kind:' "$OUT") objects rendered"

echo "[2/4] policy"
python3 scripts/k8s-policy-check.py <"$OUT"
python3 scripts/check-nginx-parity.py

echo "[3/4] schema (kubeconform, strict, Kubernetes $K8S_VERSION)"
kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" "$OUT"
kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" k8s/secret.example.yaml

echo "[4/4] cluster dry-run"
if [[ -n "${KUBECONFIG:-}" ]] && kubectl cluster-info >/dev/null 2>&1; then
  kubectl apply --dry-run=client -f "$OUT"
  # Server dry-run needs the namespace to exist, because a dry-run does not persist it.
  kubectl apply -f k8s/00-namespace.yaml >/dev/null
  kubectl apply --dry-run=server -f "$OUT"
else
  echo "      skipped: no reachable cluster (set KUBECONFIG)"
  exit 3
fi
echo "k8s-validate: all checks passed"
