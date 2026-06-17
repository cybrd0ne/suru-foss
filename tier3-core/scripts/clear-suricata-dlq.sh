#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 3 Core  ·  clear-suricata-dlq.sh
# =============================================================================
# Purpose : Purge the filled suricata-eve Logstash dead-letter queue.
#           The DLQ fills when Suricata events fail OpenSearch indexing (e.g.
#           malformed IP values rejected by an ip-typed field). With DLQ at
#           its 1 GB ceiling new failures are silently dropped.
#
# Prerequisites:
#   - Apply ignore_malformed fix to suru-ecs-template BEFORE running this
#     so restarted Logstash does not immediately refill the DLQ.
#   - Run from the repo root or tier3-core/ directory.
#
# Usage:
#   bash tier3-core/scripts/clear-suricata-dlq.sh [--dry-run] [--verbose]
# =============================================================================
set -euo pipefail
trap '_on_error $LINENO' ERR
_on_error() { echo "[ERR ] Script failed on line $1" >&2; exit 1; }

DRY_RUN=false
VERBOSE=false
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
  esac
done

CONTAINER="suru.t3.ingestion.logstash-pfsense"
DLQ_PATH="/usr/share/logstash/dead_letter_queue/suricata-eve"

_log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
_run() {
  if $DRY_RUN; then printf '[DRY-RUN] %s\n' "$*"
  else $VERBOSE && printf '[CMD] %s\n' "$*"; "$@"; fi
}

_log "Checking DLQ size in container $CONTAINER..."
DLQ_SIZE=$(docker exec "$CONTAINER" du -sh "$DLQ_PATH" 2>/dev/null | cut -f1 || echo "unknown")
_log "DLQ current size: $DLQ_SIZE"

_log "Stopping Logstash container (live-restore keeps other containers running)..."
_run docker stop "$CONTAINER"

_log "Deleting DLQ segment files at $DLQ_PATH..."
_run docker run --rm \
  --volumes-from "$CONTAINER" \
  busybox:1.37.0@sha256:7a3ebe5bfd1a4a19797d20b0c0bb39d44393e9a03fd852c0865b0f540d868df0 \
  sh -c "find ${DLQ_PATH} -type f -name '*.log' -delete && echo 'DLQ segments deleted'"

_log "Restarting Logstash container..."
_run docker start "$CONTAINER"

_log "Waiting for Logstash to be healthy (up to 120s)..."
if ! $DRY_RUN; then
  elapsed=0
  while [ "$elapsed" -lt 120 ]; do
    if docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null | grep -q "healthy"; then
      _log "Logstash is healthy."
      break
    fi
    sleep 5; elapsed=$((elapsed + 5))
    $VERBOSE && _log "  waiting... ${elapsed}s"
  done
fi

_log "Done. New DLQ size:"
if ! $DRY_RUN; then
  docker exec "$CONTAINER" du -sh "$DLQ_PATH" 2>/dev/null | cut -f1 || true
fi
