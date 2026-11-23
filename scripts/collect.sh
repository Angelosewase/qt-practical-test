#!/usr/bin/env bash
# Read-only resource and health snapshot. Run ON a VM (scripts/collect-monitoring.sh copies and runs it).
# Every section has a UTC timestamp and the host name. Tools run only on the VMs that have them:
#   every VM:            top, df, free, uptime, ss, vmstat, processes, network addresses
#   docker host:        docker ps, docker stats, compose logs of the API, Valkey memory and hit/miss stats, health
#   control plane:      kubectl get nodes/pods, kubectl top nodes/pods, app service, NodePort health
set -uo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

section() {
  printf '\n##### %s  host=%s  %s\n' "$(ts)" "$(hostname)" "$*"
}

# run LABEL COMMAND... : header, then the command with no stdin, merged output, and its exit status.
run() {
  local label="$1"; shift
  section "$label"
  printf '$ %s\n' "$*"
  "$@" </dev/null 2>&1
  printf '[exit=%s at %s]\n' "$?" "$(ts)"
}

# Same as run, but for shell pipelines (kept as one string on purpose).
runsh() {
  local label="$1" cmd="$2"
  section "$label"
  printf '$ %s\n' "$cmd"
  bash -c "$cmd" </dev/null 2>&1
  printf '[exit=%s at %s]\n' "$?" "$(ts)"
}

printf '# collect.sh on %s at %s (UTC)\n' "$(hostname)" "$(ts)"

runsh "identity" 'grep PRETTY_NAME /etc/os-release; uname -r; nproc; free -m | awk "/Mem/{print \"mem_total_mb=\"\$2}"'
run "uptime and load averages (1, 5, 15 min)" uptime
run "top (batch mode, one iteration, top 25 lines)" bash -c 'top -b -n 1 | head -n 25'
run "processes by CPU and memory" bash -c 'ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%cpu | head -n 15'
run "df -h (disk space per partition)" df -h
run "free -h (memory)" free -h
run "vmstat 1 3 (virtual memory and disk I/O)" vmstat 1 3
runsh "listening sockets (ss -tulpn)" 'sudo -n ss -tulpn 2>/dev/null || ss -tuln'
run "network addresses" ip -4 -brief addr

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  COMPOSE_FILE=/opt/projecthub/docker/docker-compose.yml
  run "docker ps (running containers and their state)" docker ps
  run "docker stats --no-stream (CPU, memory, network and I/O per container)" docker stats --no-stream
  run "compose services (health)" docker compose -f "$COMPOSE_FILE" ps
  run "API container log, last 50 lines" docker compose -f "$COMPOSE_FILE" logs --tail=50 api
  runsh "Valkey memory" "docker compose -f $COMPOSE_FILE exec -T valkey sh -c 'valkey-cli info memory | grep -E \"^used_memory_human|^used_memory_peak_human|^maxmemory_human\"'"
  runsh "Valkey hits and misses" "docker compose -f $COMPOSE_FILE exec -T valkey sh -c 'valkey-cli info stats | grep -E \"^keyspace_hits|^keyspace_misses\"'"
  runsh "Valkey cached keys (projecthub:*)" "docker compose -f $COMPOSE_FILE exec -T valkey sh -c 'valkey-cli --scan --pattern \"projecthub:*\" | wc -l'"
  runsh "application health through NGINX (port 80)" 'curl -s -m 10 -w "  HTTP %{http_code}\n" http://127.0.0.1/api/health; curl -s -o /dev/null -m 10 -w "frontend / HTTP %{http_code}\n" http://127.0.0.1/'
fi

if command -v kubectl >/dev/null 2>&1 && kubectl version --client >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
  run "kubernetes nodes, status and readiness" kubectl get nodes -o wide
  run "kubernetes pods in all namespaces (status, restarts, placement)" kubectl get pods -A -o wide
  run "kubernetes node resource use (metrics-server)" kubectl top nodes
  run "kubernetes pod resource use (metrics-server)" kubectl top pods -A
  run "application services in qt-spring-app" kubectl -n qt-spring-app get svc
  run "application pods in qt-spring-app" kubectl -n qt-spring-app get pods -o wide
  runsh "application health through NodePort 30080" 'curl -s -m 10 -w "  HTTP %{http_code}\n" http://127.0.0.1:30080/api/health; curl -s -o /dev/null -m 10 -w "frontend / HTTP %{http_code}\n" http://127.0.0.1:30080/'
fi

printf '\n# end of collect.sh on %s at %s\n' "$(hostname)" "$(ts)"
