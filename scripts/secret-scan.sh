#!/usr/bin/env bash
# Scans for secret values loaded from .private/secrets.env. Matches are never printed.
#   --staged   added lines of the index (used by the pre-commit hook)
#   --tree     all tracked and untracked (non-ignored) files in the working tree
#   --history  every added line in every commit on every ref
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
SECRETS_FILE=".private/secrets.env"
MODE="${1:---staged}"
SECRET_KEYS="PROXMOX_TOKEN_SECRET GITLAB_TOKEN DOCKERHUB_TOKEN VM_PASSWORD"
SHAPE_REGEX='glpat-[A-Za-z0-9_.-]{20,}|PVEAPIToken[=][^[:space:]]+|BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY'

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "secret-scan: $SECRETS_FILE missing, nothing to compare against" >&2
  exit 1
fi

TMPDIR_SCAN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SCAN"' EXIT
LITERALS="$TMPDIR_SCAN/literals"
: >"$LITERALS"

count=0
for key in $SECRET_KEYS; do
  value="$(grep -E "^${key}=" "$SECRETS_FILE" | head -1 | cut -d= -f2- | tr -d "'\"" || true)"
  if [[ -z "$value" || "$value" == \<* ]]; then
    continue
  fi
  printf '%s\n' "$value" >>"$LITERALS"
  count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
  echo "secret-scan: no secret values configured, refusing to pass blindly" >&2
  exit 1
fi

hits=0
report() { echo "secret-scan: $1" >&2; hits=$((hits + 1)); }

# Checks text given as $2 for configured literals and token shapes. Runs in the main shell so hits counts.
check_text() {
  local label="$1" text="$2" textfile="$TMPDIR_SCAN/text.txt"
  printf '%s\n' "$text" >"$textfile"
  if grep -F -q -f "$LITERALS" "$textfile"; then
    report "$label contains a configured secret value (redacted)"
  fi
  if grep -E -q -- "$SHAPE_REGEX" "$textfile"; then
    report "$label contains a secret-shaped token (redacted)"
  fi
}

case "$MODE" in
  --staged)
    ADDED="$(git diff --cached -U0 --no-color | grep -E '^\+' | grep -v '^+++' || true)"
    check_text "staged changes" "$ADDED"
    ;;
  --tree)
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      grep -I -F -q -f "$LITERALS" "$f" && report "$f contains a configured secret value (redacted)" || true
      grep -I -E -q -- "$SHAPE_REGEX" "$f" && report "$f contains a secret-shaped token (redacted)" || true
    done < <(git ls-files --cached --others --exclude-standard)
    ;;
  --history)
    HISTORY_FILE="$TMPDIR_SCAN/history.txt"
    git log --all -p --no-color >"$HISTORY_FILE"
    grep -F -q -f "$LITERALS" "$HISTORY_FILE" && report "git history contains a configured secret value (redacted)" || true
    grep -E -q -- "$SHAPE_REGEX" "$HISTORY_FILE" && report "git history contains a secret-shaped token (redacted)" || true
    ;;
  *)
    echo "usage: $0 [--staged|--tree|--history]" >&2
    exit 2
    ;;
esac

if [[ "$hits" -gt 0 ]]; then
  echo "secret-scan: FAILED ($MODE, $hits finding(s))" >&2
  exit 1
fi
echo "secret-scan: clean ($MODE, $count configured secret value(s) checked)"
