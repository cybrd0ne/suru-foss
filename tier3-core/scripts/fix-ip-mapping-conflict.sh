#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 3 Core  ·  fix-ip-mapping-conflict.sh
# =============================================================================
# Purpose : Resolve the suru-suricata-* IP field mapping conflict.
#           Indices created before the suru-ecs-template was applied have
#           source.ip/destination.ip mapped as text (dynamic). Newer indices
#           have them as ip type. The mixed types cause the index pattern to
#           report a conflict and Terms aggregations to fail in Dashboards.
#
# Actions:
#   1. Re-PUT the suru-ecs-template (picks up ignore_malformed change).
#   2. Delete pre-template Suricata indices (those with text-typed source.ip).
#   3. Refresh the suru-ids-index-pattern field list in Dashboards.
#
# Usage:
#   bash tier3-core/scripts/fix-ip-mapping-conflict.sh [--dry-run] [--verbose]
#
# Run from the repo root or tier3-core/ directory.
# Requires OPENSEARCH_INITIAL_ADMIN_PASSWORD and OPENSEARCH_DASHBOARDS_PASSWORD
# in tier3-core/.env (loaded automatically).
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
trap '_on_error $LINENO' ERR
_on_error() { echo "[ERR ] Script failed on line $1" >&2; exit 1; }

_TMPFILES=()
_cleanup() { local f; for f in "${_TMPFILES[@]:-}"; do [[ -n "$f" ]] && rm -f -- "$f"; done; }
trap _cleanup EXIT

DRY_RUN=false
VERBOSE=false
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER3_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${TIER3_DIR}/.env"

_log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
_warn() { printf '[%s] [WARN] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
_run()  {
  # Redact -u / --user user:pass to prevent credentials appearing in logs/stdout
  local _redacted
  _redacted="$(printf '%s ' "$@" | sed -E 's/(-u|--user) [^[:space:]]+/\1 ***REDACTED***/g')"
  if $DRY_RUN; then
    printf '[DRY-RUN] %s\n' "${_redacted}"
  else
    $VERBOSE && printf '[CMD] %s\n' "${_redacted}"
    "$@"
  fi
}

[[ -f "$ENV_FILE" ]] || { echo "[ERR ] .env not found: $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

OS_PASS="${OPENSEARCH_INITIAL_ADMIN_PASSWORD:?OPENSEARCH_INITIAL_ADMIN_PASSWORD must be set}"
DASH_USER="${OPENSEARCH_DASHBOARDS_USER:-kibanaserver}"
DASH_PASS="${OPENSEARCH_DASHBOARDS_PASSWORD:?OPENSEARCH_DASHBOARDS_PASSWORD must be set}"
OS_CONTAINER="suru.t3.datalake.opensearch"
DASH_CONTAINER="suru.t3.datalake.dashboards"
TEMPLATE_FILE="${TIER3_DIR}/config/opensearch/index-templates/suru-ecs-template.json"

# ── Step 1: Re-PUT the ECS template (picks up ignore_malformed) ──────────────
_log "Step 1: Re-applying suru-ecs-template..."
_BODY_FILE="$(mktemp)"
_TMPFILES+=("$_BODY_FILE")
sed -n '/^{/,$p' "$TEMPLATE_FILE" > "$_BODY_FILE"
if $DRY_RUN; then
  _log "[DRY-RUN] docker exec -i $OS_CONTAINER curl -sk --user ***REDACTED*** -X PUT https://localhost:9200/_index_template/suru-ecs-template -H Content-Type: application/json --data-binary @- < $_BODY_FILE"
else
  $VERBOSE && _log "[CMD] docker exec -i $OS_CONTAINER curl -sk --user ***REDACTED*** -X PUT https://localhost:9200/_index_template/suru-ecs-template -H Content-Type: application/json --data-binary @-"
  docker exec -i "$OS_CONTAINER" curl -sk --user "admin:${OS_PASS}" \
    -X PUT "https://localhost:9200/_index_template/suru-ecs-template" \
    -H 'Content-Type: application/json' \
    --data-binary @- < "$_BODY_FILE"
fi
_log "Template applied."

# ── Step 2: Find and delete pre-template Suricata indices ────────────────────
_log "Step 2: Finding Suricata indices with text-typed source.ip..."
STALE_INDICES=$(docker exec "$OS_CONTAINER" curl -sk -u "admin:${OS_PASS}" \
  "https://localhost:9200/_cat/indices/suru-suricata-*?h=index" 2>/dev/null \
  | while read -r idx; do
      TYPE=$(docker exec "$OS_CONTAINER" curl -sk -u "admin:${OS_PASS}" \
        "https://localhost:9200/${idx}/_mapping/field/source.ip" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); \
          props=list(list(d.values())[0]['mappings'].values()); \
          print(props[0].get('mapping',{}).get('source.ip',{}).get('type','?'))" 2>/dev/null || echo "?")
      if [ "$TYPE" = "text" ]; then echo "$idx"; fi
    done)

if [ -z "$STALE_INDICES" ]; then
  _log "No stale (text-typed) Suricata indices found — nothing to delete."
else
  _log "Stale indices to delete: $STALE_INDICES"
  while IFS= read -r idx; do
    [[ -z "$idx" ]] && continue
    if [[ ! "$idx" =~ ^suru-suricata-[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; then
      _warn "Skipping unexpected index name (failed validation): $idx"
      continue
    fi
    _warn "Deleting $idx (source.ip was text-typed, pre-template data)"
    _run docker exec "$OS_CONTAINER" curl -sk -u "admin:${OS_PASS}" \
      -X DELETE "https://localhost:9200/${idx}"
    _log "Deleted: $idx"
  done <<< "$STALE_INDICES"
fi

# ── Step 3: Refresh index pattern field list in Dashboards ───────────────────
_log "Step 3: Refreshing suru-ids-index-pattern field list in Dashboards..."
_run docker exec "$DASH_CONTAINER" curl -sk \
  -u "${DASH_USER}:${DASH_PASS}" \
  -X POST "https://localhost:5601/dashboards/api/saved_objects/index-pattern/suru-ids-index-pattern/_fields_for_wildcard" \
  -H "securitytenant: global" \
  -H "Content-Type: application/json" \
  -d '{"fields":"*","include_unmapped":true}' > /dev/null 2>&1 || _warn "Field refresh endpoint not available — refresh manually in Stack Management."

_log "Done. Verify in Dashboards: Stack Management → Index Patterns → suru-ids-index-pattern → Refresh fields."
_log "Then confirm source.ip/destination.ip show type 'ip' (not 'conflict')."
