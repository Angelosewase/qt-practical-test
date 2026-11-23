#!/usr/bin/env bash
# Runs scripts/collect.sh on every VM over SSH and saves the timestamped output to monitoring/<hostname>/.
# The VM name is taken from the VM itself (hostname) and must match the Terraform name, or the run stops.
# Nothing is changed on the VMs: the script is copied to /tmp, run, and removed.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
KEY="$ROOT/.private/ssh/id_ed25519"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=20)
SCP=(scp -i "$KEY" -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=20)

IPS="$(terraform -chdir=iac output -json vm_ips)"
mapfile -t NAMES < <(jq -r 'keys[]' <<<"$IPS")

for name in "${NAMES[@]}"; do
  ip="$(jq -r --arg n "$name" '.[$n]' <<<"$IPS")"
  remote="/tmp/collect-$STAMP.sh"
  echo "collecting from $name ($ip)"
  "${SCP[@]}" scripts/collect.sh "devops@$ip:$remote"
  actual="$("${SSH[@]}" "devops@$ip" hostname)"
  if [[ "$actual" != "$name" ]]; then
    echo "collect-monitoring: $ip reports hostname '$actual', expected '$name'" >&2
    "${SSH[@]}" "devops@$ip" "rm -f $remote" || true
    exit 1
  fi
  out_dir="$ROOT/monitoring/$name"
  out_file="$out_dir/collect-$STAMP.txt"
  mkdir -p "$out_dir"
  "${SSH[@]}" "devops@$ip" "bash $remote; rm -f $remote" >"$out_file"
  echo "  saved $out_file ($(wc -l <"$out_file") lines)"
done
echo "collect-monitoring: done ($STAMP)"
