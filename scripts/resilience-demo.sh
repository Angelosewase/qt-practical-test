#!/usr/bin/env bash
# Kubernetes resilience proof for the qt-spring-app namespace. Every line is timestamped (UTC).
#
#   a. pods before
#   b. scale the API to 3 replicas
#   c. delete one API pod while a request loop runs against the NodePort (one request every 0.2 s)
#   d. scale Valkey to 0: /api/health reports cache "down" and a real login and list still work; Valkey back to 1
#   e. scale the API back to its normal replica count
#
# Robustness:
#   - every kubectl call is retried (KUBECTL_ATTEMPTS). Each failed attempt is logged and counted.
#   - before each phase the API server must answer /readyz three times in a row (STABLE_WAIT seconds at most).
#   - on exit, always, even after a failure or Ctrl-C: Valkey goes back to 1 and the API to NORMAL_API_REPLICAS.
#   - the verdict is CLEAN only if: no kubectl errors, no failed phase, no failed request, final state correct.
#     Otherwise the script exits 1 and says why.
#
# Usage (laptop or control plane):
#   KUBECONFIG=.private/kubeconfig scripts/resilience-demo.sh | tee monitoring/resilience-evidence.txt
# Overrides: NODE_IP (192.168.160.17), NODEPORT (30080), NORMAL_API_REPLICAS (2), VALKEY_NORMAL (1).
# No secrets are used or printed. The seeded test account (README) is used for the login check.
set -uo pipefail

NS=qt-spring-app
NODE_IP="${NODE_IP:-192.168.160.17}"
NODEPORT="${NODEPORT:-30080}"
NORMAL_API_REPLICAS="${NORMAL_API_REPLICAS:-2}"
VALKEY_NORMAL="${VALKEY_NORMAL:-1}"
KUBECTL_ATTEMPTS="${KUBECTL_ATTEMPTS:-5}"
STABLE_WAIT="${STABLE_WAIT:-240}"
BASE="http://${NODE_IP}:${NODEPORT}"
WORK="$(mktemp -d)"
LOOP_LOG="$WORK/loop.log"
LOOP_PID=0
ERRORS=0
FAILED_PHASES=()
PHASES=()
RESTORED=0
FINISHED=0
: >"$LOOP_LOG"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*"; }

# kc ARGS...: runs kubectl in the namespace with retries, logs the command and its output.
kc() {
  local attempt out rc
  log "\$ kubectl -n $NS $*"
  for attempt in $(seq 1 "$KUBECTL_ATTEMPTS"); do
    out="$(kubectl -n "$NS" "$@" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      printf '%s\n' "$out" | while IFS= read -r line; do log "  $line"; done
      return 0
    fi
    ERRORS=$((ERRORS + 1))
    log "  KUBECTL ERROR (attempt $attempt/$KUBECTL_ATTEMPTS, exit $rc): $(printf '%s' "$out" | head -n1)"
    sleep $((attempt * 4))
  done
  log "  GIVING UP after $KUBECTL_ATTEMPTS attempts: kubectl -n $NS $*"
  return 1
}

# kq ARGS...: quiet query with retries. Prints the output on stdout. Errors are logged and counted.
kq() {
  local attempt out rc
  for attempt in $(seq 1 "$KUBECTL_ATTEMPTS"); do
    out="$(kubectl -n "$NS" "$@" 2>"$WORK/err")"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      printf '%s' "$out"
      return 0
    fi
    ERRORS=$((ERRORS + 1))
    log "  KUBECTL ERROR in query (attempt $attempt/$KUBECTL_ATTEMPTS, exit $rc): $(head -n1 "$WORK/err")"
    sleep $((attempt * 4))
  done
  return 1
}

# api_server_stable: /readyz must answer "ok" three times in a row.
api_server_stable() {
  local ok=0 out deadline=$((SECONDS + STABLE_WAIT))
  while (( SECONDS < deadline )); do
    out="$(timeout 15 kubectl get --raw /readyz 2>&1)"
    if [[ "$out" == "ok" ]]; then
      ok=$((ok + 1))
      if (( ok >= 3 )); then
        log "  API server stable (/readyz ok x3)"
        return 0
      fi
    else
      ok=0
      ERRORS=$((ERRORS + 1))
      log "  API server not ready: $(printf '%s' "$out" | head -n1)"
    fi
    sleep 3
  done
  log "  TIMEOUT: API server not stable within ${STABLE_WAIT}s"
  return 1
}

# ready_pods SELECTOR: number of Ready pods that are not terminating.
ready_pods() {
  local out
  out="$(kq get pods -l "$1" -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}')" || { echo "?"; return; }
  printf '%s\n' "$out" | awk -F'\t' '$1=="" && $2=="true"{n++} END{print n+0}'
}

# wait_ready SELECTOR WANT TIMEOUT_S: waits until WANT pods are Ready. Logs only changes.
wait_ready() {
  local sel="$1" want="$2" limit="$3" deadline last="" n
  deadline=$((SECONDS + limit))
  while (( SECONDS < deadline )); do
    n="$(ready_pods "$sel")"
    if [[ "$n" != "$last" ]]; then
      log "  Ready pods for $sel: $n of $want"
      last="$n"
    fi
    if [[ "$n" == "$want" ]]; then
      return 0
    fi
    sleep 3
  done
  log "  TIMEOUT: $want Ready pods for $sel not reached within ${limit}s (last: $last)"
  return 1
}

health_json() { curl -s -m 10 "$BASE/api/health"; }

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

stop_loop() {
  if (( LOOP_PID > 0 )); then
    kill "$LOOP_PID" 2>/dev/null
    wait "$LOOP_PID" 2>/dev/null
    LOOP_PID=0
  fi
}

phase_start() { PHASE_START_TS="$(ts)"; log "=== $1 ==="; }
phase_end() {
  PHASES+=("$1|$PHASE_START_TS|$(ts)")
  log "--- phase $1 finished"
}
# run_phase NAME FUNCTION: runs a phase and records a failure without stopping the rest.
run_phase() {
  local name="$1" fn="$2"
  phase_start "$name"
  if "$fn"; then
    phase_end "$name"
  else
    FAILED_PHASES+=("$name")
    log "--- phase $name FAILED (see messages above)"
    phase_end "$name"
  fi
  echo
}

phase_a() {
  kc get pods -o wide || return 1
  kc get deploy || return 1
  log "API health before: $(health_json)"
}

phase_b() {
  api_server_stable || return 1
  kc scale deploy/api --replicas=3 || return 1
  kc rollout status deploy/api --timeout=240s || return 1
  wait_ready "app.kubernetes.io/name=api" 3 240 || return 1
  kc get pods -l app.kubernetes.io/name=api -o wide
}

phase_c() {
  api_server_stable || return 1
  local victim
  victim="$(kq get pods -l app.kubernetes.io/name=api -o jsonpath='{.items[0].metadata.name}')" || return 1
  if [[ -z "$victim" ]]; then
    log "  no API pod found to delete"
    return 1
  fi
  log "deleting pod $victim (graceful: SIGTERM, then replacement)"
  kc delete pod "$victim" --wait=false || return 1
  local i
  for i in $(seq 1 6); do
    kc get pods -l app.kubernetes.io/name=api
    sleep 5
  done
  wait_ready "app.kubernetes.io/name=api" 3 240 || return 1
  kc get pods -l app.kubernetes.io/name=api -o wide
}

phase_d() {
  api_server_stable || return 1
  local ok=0 h login_body token list_code count i
  kc scale deploy/valkey --replicas=0 || return 1
  kc wait --for=delete pod -l app.kubernetes.io/name=valkey --timeout=120s || log "  note: wait for Valkey pod deletion did not complete cleanly"
  for i in 1 2 3; do
    h="$(health_json)"
    log "  health sample $i (cache down expected): $h"
    printf '%s' "$h" | grep -q '"cache":"down"' && ok=$((ok + 1))
    sleep 2
  done
  if (( ok < 3 )); then
    log "  health did not report cache down on every sample (got $ok of 3)"
    FAILED_PHASES+=("d: cache not reported down")
  fi
  login_body="$(curl -s -m 10 -H 'Content-Type: application/json' -d '{"email":"manager@qt.rw","password":"Manager@123"}' "$BASE/api/auth/login")"
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
    [[ "$list_code" == 200 ]] || FAILED_PHASES+=("d: list with cache down HTTP $list_code")
  else
    log "login with the cache down: FAILED (no token)"
    FAILED_PHASES+=("d: login with cache down failed")
  fi
  kc scale deploy/valkey --replicas="$VALKEY_NORMAL" || return 1
  kc rollout status deploy/valkey --timeout=240s || return 1
  wait_ready "app.kubernetes.io/name=valkey" "$VALKEY_NORMAL" 240 || return 1
  for i in $(seq 1 60); do
    h="$(health_json)"
    printf '%s' "$h" | grep -q '"cache":"up"' && break
    sleep 2
  done
  log "API health after Valkey is back: $h"
  printf '%s' "$h" | grep -q '"cache":"up"' || { log "  TIMEOUT: cache not reported up within 120s"; return 1; }
}

phase_e() {
  api_server_stable || return 1
  kc scale deploy/api --replicas="$NORMAL_API_REPLICAS" || return 1
  kc rollout status deploy/api --timeout=240s || return 1
  wait_ready "app.kubernetes.io/name=api" "$NORMAL_API_REPLICAS" 240 || return 1
  kc get pods -o wide
}

# restore_state: always runs at the end (also after a failure or Ctrl-C). Retries each step.
restore_state() {
  (( RESTORED == 1 )) && return 0
  RESTORED=1
  log "=== restore: Valkey to $VALKEY_NORMAL, API to $NORMAL_API_REPLICAS (runs on every exit) ==="
  kc scale deploy/valkey --replicas="$VALKEY_NORMAL"
  kc scale deploy/api --replicas="$NORMAL_API_REPLICAS"
  kc rollout status deploy/valkey --timeout=240s
  kc rollout status deploy/api --timeout=240s
  wait_ready "app.kubernetes.io/name=valkey" "$VALKEY_NORMAL" 240
  wait_ready "app.kubernetes.io/name=api" "$NORMAL_API_REPLICAS" 240
}

finish() {
  (( FINISHED == 1 )) && return 0
  FINISHED=1
  stop_loop
  restore_state
  local final_api final_valkey final_health total fails
  final_api="$(kq get deploy api -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
  final_valkey="$(kq get deploy valkey -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
  final_health="$(health_json)"
  log "=== request loop summary ==="
  total="$(wc -l <"$LOOP_LOG" | tr -d ' ')"
  fails="$(awk '$4 != "status=200"' "$LOOP_LOG" | wc -l | tr -d ' ')"
  log "requests sent: $total   non-200 or failed: $fails"
  local p name rest s e n f
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
  log "=== verdict ==="
  log "final state: api ready/spec=$final_api  valkey ready/spec=$final_valkey  health=$final_health"
  log "kubectl errors seen (each retried): $ERRORS"
  if (( ${#FAILED_PHASES[@]} > 0 )); then
    log "failed phases: ${FAILED_PHASES[*]}"
  else
    log "failed phases: none"
  fi
  local clean=1
  (( ERRORS == 0 )) || clean=0
  (( ${#FAILED_PHASES[@]} == 0 )) || clean=0
  [[ "$fails" == 0 ]] || clean=0
  [[ "$final_api" == "$NORMAL_API_REPLICAS/$NORMAL_API_REPLICAS" ]] || clean=0
  [[ "$final_valkey" == "$VALKEY_NORMAL/$VALKEY_NORMAL" ]] || clean=0
  printf '%s' "$final_health" | grep -q '"cache":"up"' || clean=0
  if (( clean == 1 )); then
    log "RESULT: CLEAN (no kubectl errors, no failed phase, no failed request, final state correct)"
    return 0
  fi
  log "RESULT: NOT CLEAN (see the messages above)"
  return 1
}

on_signal() { log "interrupted: restoring state before exit"; exit 130; }
trap on_signal INT TERM
trap 'stop_loop; restore_state; rm -rf "$WORK"' EXIT

log "resilience-demo start: namespace=$NS node=$NODE_IP nodeport=$NODEPORT normal api=$NORMAL_API_REPLICAS valkey=$VALKEY_NORMAL"
log "cluster context: $(kubectl config current-context 2>/dev/null || echo unknown)"
echo

run_phase "a. pods before" phase_a
start_loop
echo
run_phase "b. scale the API to 3 replicas" phase_b
run_phase "c. delete one API pod while the request loop runs" phase_c
run_phase "d. scale Valkey to 0 (cache outage)" phase_d
run_phase "e. scale the API back to $NORMAL_API_REPLICAS replicas" phase_e

finish
verdict=$?
exit "$verdict"
