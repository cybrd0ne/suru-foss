#!/usr/bin/env bash
# SURU Platform — Suricata rule update script (scheduled via cron/systemd timer)
# Idempotent: safe to run multiple times.
# Usage: ./update-rules.sh [--dry-run] [--verbose]

set -euo pipefail

trap 'echo "[ERROR] update-rules.sh failed at line ${LINENO}" >&2' ERR

DRY_RUN=false
VERBOSE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=true  ;;
    --verbose)  VERBOSE=true  ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "[ERROR] Missing: docker" >&2; exit 1; }

log() { echo "[INFO]  $*"; }
run() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    $VERBOSE && log "→ $*" || true
    "$@"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER1_DIR="$(dirname "$SCRIPT_DIR")"

log "Updating Suricata rules ..."
# TODO(SEC-037): pin when Docker Hub auth is available for digest verification
run docker run --rm \
  -v "${TIER1_DIR}/suricata:/etc/suricata" \
  jasonish/suricata-update:latest \
  --config /etc/suricata/update.yaml

log "Reloading Suricata rules (live reload) ..."
run docker exec suru-suricata suricatasc -c reload-rules

log "Rule update complete"
