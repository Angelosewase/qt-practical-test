#!/usr/bin/env bash
# Kubernetes resilience proof for the qt-spring-app namespace. Every output line is timestamped (UTC).
#
#   a. pods before
#   b. scale the API to 3 replicas
#   c. delete one API pod while a request loop runs against the NodePort (one request every 0.2 s)
#   d. scale Valkey to 0: /api/health reports cache "down" and a real login and list still work; then Valkey back to 1
#   e. scale the API back to its normal replica count
#
# Runs from any machine that can reach the cluster (the laptop, or the control-plane node itself).
#   KUBECONFIG=.private/kubeconfig scripts/resilience-demo.sh | tee monitoring/resilience-evidence.txt
# Environment overrides: NODE_IP (default 192.168.160.17), NODEPORT (30080), NORMAL_API_REPLICAS (2).
# No secrets are used or printed. The seeded test account (README) is used for the login check.
set -uo pipefail

NS=qt-spring-app
NODE_IP="${NODE_IP:-192.168.160.17}"
NODEPORT="${NODEPORT:-30080}"
NORMAL_API_REPLICAS="${NORMAL_API_REPLICAS:-2}"
BASE="http://${NODE_IP}:${NODEPORT}"
WORK="$(mktemp -d)"
LOOP_LOG="$WORK/loop.log"
# Never signal PID 0: "kill 0" would signal the whole process group, including the caller.
trap '[[ "${LOOP_PID:-0}" -gt 0 ]] && kill "$LOOP_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
: >"$LOOP_LOG"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*"; }
kc() {
  log "\$ kubectl $*"
  kubectl -n "$NS" "$@" 2>&1 | while IFS= read -r line; do log "  $line"; done
}
phase_start() { PHASE_START_TS="$(ts)"; log "=== $1 ==="; }
phase_end() {
  PHASE_END_TS="$(ts)"
  log "--- phase $1 finished"
  PHASES+=("$1|$PHASE_START_TS|$PHASE_END_TS")
}
api_ready_count() {
  kubectl -n "$NS" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null
}

PHASES=()

start_loop() {
  (
    while true; do
      r="$(curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' "$BASE/api/health" 2>/dev/null || true)"
      code="${r%% *}"; t="${r#* }"
      [[ -z "$code" ]] && code=000
      printf '%s GET %s/api/health status=%s time=%ss\n' "$(ts)" "$BASE" "$code" "$t" >>"$LOOP_LOG"
      sleep 0.2
    done
  ) </dev/null >/dev/null 2>&1 &
  LOOP_PID=$!
  log "request loop started (pid $LOOP_PID): GET $BASE/api/health every 0.2 s"
}

wait_pods_ready() {
  # wait_pods_ready <label-selector> <count>
  local sel="$1" want="$2" i ready
  for i in $(seq 1 90); do
    ready="$(kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c true || true)"
    if [[ "$ready" -eq "$want" ]]; then
      log "  $ready of $want pods Ready for $sel"
      return 0
    fi
    sleep 2
  done
  log "  TIMEOUT waiting for $want Ready pods for $sel (last: $ready)"
  return 1
}

health_json() { curl -s -m 10 "$BASE/api/health"; }

log "resilience-demo start: namespace=$NS node=$NODE_IP nodeport=$NODEPORT"
log "cluster context: $(kubectl config current-context 2>/dev/null || echo unknown)"
echo

# ---- a. before ---------------------------------------------------------------
phase_start "a. pods before"
kc get pods -o wide
kc get deploy
log "API health before: $(health_json)"
phase_end "a"
echo

start_loop
echo

# ---- b. scale the API to 3 ----------------------------------------------------
phase_start "b. scale the API to 3 replicas"
kc scale deploy/api --replicas=3
kc rollout status deploy/api --timeout=180s
wait_pods_ready "app.kubernetes.io/name=api" 3
kc get pods -l app.kubernetes.io/name=api -o wide
phase_end "b"
echo

# ---- c. delete one API pod during the loop -------------------------------------
phase_start "c. delete one API pod while the request loop runs"
victim="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
log "deleting pod $victim (graceful: SIGTERM, then replacement)"
kc delete pod "$victim" --wait=false
for i in $(seq 1 12); do
  kc get pods -l app.kubernetes.io/name=api
  if [[ "$(api_ready_count)" == 3 ]] && ! kubectl -n "$NS" get pod "$victim" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
wait_pods_ready "app.kubernetes.io/name=api" 3
kc get pods -l app.kubernetes.io/name=api -o wide
phase_end "c"
echo

# ---- d. cache outage -----------------------------------------------------------
phase_start "d. scale Valkey to 0 (cache outage)"
kc scale deploy/valkey --replicas=0
kc wait --for=delete pod -l app.kubernetes.io/name=valkey --timeout=120s
log "API health while the cache is down: $(health_json)"
for i in $(seq 1 3); do
  log "  health sample $i: $(health_json)"
  sleep 2
done
# Real login and a real list, through the NodePort, while the cache is down.
login_body="$(curl -s -m 10 -H 'Content-Type: application/json' \
  -d '{"email":"manager@qt.rw","password":"Manager@123"}' "$BASE/api/auth/login")"
token="$(printf '%s' "$login_body" | python3 -c 'import sys, json
try:
    print(json.load(sys.stdin)["token"])
except Exception:
    print("")' 2>/dev/null)"
if [[ -n "$token" ]]; then
  log "login as manager@qt.rw with the cache down: OK (token received, not shown)"
  list_code="$(curl -s -o "$WORK/list.json" -w '%{http_code}' -m 10 -H "Authorization: Bearer $token" "$BASE/api/projects")"
  count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORK/list.json" 2>/dev/null || echo '?')"
  log "list projects with the cache down: HTTP $list_code, $count project(s) returned"
else
  log "login with the cache down: FAILED (no token)"
fi
kc scale deploy/valkey --replicas=1
kc rollout status deploy/valkey --timeout=180s
for i in $(seq 1 30); do
  h="$(health_json)"
  if printf '%s' "$h" | grep -q '"cache":"up"'; then break; fi
  sleep 2
done
log "API health after Valkey is back: $h"
phase_end "d"
echo

# ---- e. back to the normal replica count -------------------------------------
phase_start "e. scale the API back to $NORMAL_API_REPLICAS replicas"
kc scale deploy/api --replicas="$NORMAL_API_REPLICAS"
kc rollout status deploy/api --timeout=180s
wait_pods_ready "app.kubernetes.io/name=api" "$NORMAL_API_REPLICAS"
kc get pods -o wide
phase_end "e"
echo

kill "$LOOP_PID" 2>/dev/null
wait "$LOOP_PID" 2>/dev/null
LOOP_PID=0

# ---- summary --------------------------------------------------------------------
log "=== request loop summary ==="
total="$(wc -l <"$LOOP_LOG" | tr -d ' ')"
fails="$(awk '$4 != "status=200"' "$LOOP_LOG" | wc -l | tr -d ' ')"
log "requests sent: $total   non-200 or failed: $fails"
for p in "${PHASES[@]}"; do
  name="${p%%|*}"; rest="${p#*|}"; s="${rest%%|*}"; e="${rest#*|}"
  n="$(awk -v s="$s" -v e="$e" '$1 >= s && $1 <= e' "$LOOP_LOG" | wc -l | tr -d ' ')"
  f="$(awk -v s="$s" -v e="$e" '$1 >= s && $1 <= e && $4 != "status=200"' "$LOOP_LOG" | wc -l | tr -d ' ')"
  log "  phase $name ($s .. $e): requests=$n failed=$f"
done
if [[ "$fails" -gt 0 ]]; then
  log "failed requests (timestamp, status):"
  awk '$4 != "status=200" {print "  " $1, $4, $5}' "$LOOP_LOG"
fi
log "resilience-demo finished"
