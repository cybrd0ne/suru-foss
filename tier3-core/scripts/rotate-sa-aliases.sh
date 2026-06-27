#!/usr/bin/env bash
# =============================================================================
# SURU (foss) — tier3-core/scripts/rotate-sa-aliases.sh
# =============================================================================
# Purpose : Rotate the OpenSearch index aliases used by Security Analytics
#           detectors so they point to today's dated index.
#
# Background:
#   The SA doc-level monitor API rejects wildcard index patterns and names
#   containing dots. Detectors reference stable aliases (suru-zeek-current,
#   suru-suricata-current). Logstash rolls to a new dated index each midnight
#   UTC (suru-<type>-YYYY.MM.dd), so the alias falls one day behind unless
#   rotated. This script performs the rotation idempotently.
#
#   Correlation rules are exempt — their API accepts wildcard index patterns
#   directly (confirmed live 2026-06-26).
#
# Alias → index-prefix map (extend when a new detector log type is added):
#   suru-zeek-current      → suru-zeek-YYYY.MM.dd
#   suru-suricata-current  → suru-suricata-YYYY.MM.dd
#
# Idempotency:
#   Safe to run multiple times per day. If the alias already points to
#   today's dated index the script logs "no-op" and exits 0.
#
# Run mode:
#   The script calls OpenSearch via `docker exec` into the running container
#   — no host-port exposure required. Run it on the SIEM Docker host.
#
# Usage:
#   bash rotate-sa-aliases.sh [--dry-run] [--verbose]
#
# Required env:
#   OPENSEARCH_INITIAL_ADMIN_PASSWORD   OpenSearch admin password (from .env)
#
# Optional env (defaults shown):
#   OPENSEARCH_CONTAINER=suru.t3.datalake.opensearch
#   OS_USER=admin
#   OS_PORT=9200
#
# System cron setup (SIEM host) — runs daily at 00:10 UTC:
#   sudo tee /etc/cron.d/suru-alias-rotate <<'CRON'
#   10 0 * * * root \
#     OPENSEARCH_INITIAL_ADMIN_PASSWORD="$(cat /etc/suru/opensearch-pass)" \
#     /opt/suru/tier3-core/scripts/rotate-sa-aliases.sh \
#     >> /var/log/suru-alias-rotate.log 2>&1
#   CRON
#
# Or add to the SIEM host user's crontab (crontab -e):
#   OPENSEARCH_INITIAL_ADMIN_PASSWORD=<password>
#   10 0 * * * /opt/suru/tier3-core/scripts/rotate-sa-aliases.sh >> /var/log/suru-alias-rotate.log 2>&1
#
# Verification after rotation:
#   docker exec suru.t3.datalake.opensearch \
#     curl -sk -u admin:$PASS \
#     "https://localhost:9200/_cat/aliases/suru-zeek-current,suru-suricata-current?v"
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

_ts()       { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_info()  { printf '[%s] [INFO]  %s\n' "$(_ts)" "$*"; }
log_warn()  { printf '[%s] [WARN]  %s\n' "$(_ts)" "$*" >&2; }
log_die()   { printf '[%s] [ERROR] %s\n' "$(_ts)" "$*" >&2; exit 1; }

# ── Flags ──────────────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false

for _arg in "$@"; do
  case "${_arg}" in
    --dry-run)  DRY_RUN=true ;;
    --verbose)  VERBOSE=true ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) log_die "Unknown argument: ${_arg}  (use --help)" ;;
  esac
done
unset _arg

# ── Config ─────────────────────────────────────────────────────────────────────
: "${OPENSEARCH_INITIAL_ADMIN_PASSWORD:?OPENSEARCH_INITIAL_ADMIN_PASSWORD must be set}"

OPENSEARCH_CONTAINER="${OPENSEARCH_CONTAINER:-suru.t3.datalake.opensearch}"
OS_USER="${OS_USER:-admin}"
OS_PORT="${OS_PORT:-9200}"
PASS="${OPENSEARCH_INITIAL_ADMIN_PASSWORD}"
BASE="https://localhost:${OS_PORT}"
TODAY="$(date -u '+%Y.%m.%d')"

# ── Dependency check ───────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || log_die "docker is required but not found"
docker inspect "${OPENSEARCH_CONTAINER}" >/dev/null 2>&1 \
  || log_die "Container '${OPENSEARCH_CONTAINER}' is not running — start the datalake stack first"

# ── Helpers ────────────────────────────────────────────────────────────────────
_os_curl() {
  docker exec "${OPENSEARCH_CONTAINER}" curl -sk -u "${OS_USER}:${PASS}" "$@"
}

# ── Core logic ─────────────────────────────────────────────────────────────────
log_info "=== SURU SA alias rotation — target date: ${TODAY} ==="
${DRY_RUN}  && log_info "Mode: DRY-RUN (no API calls will be made)"
${VERBOSE}  && log_info "Container: ${OPENSEARCH_CONTAINER} | user: ${OS_USER} | port: ${OS_PORT}"

rotate_alias() {
  local alias_name="$1"
  local index_prefix="$2"
  local target_index="${index_prefix}-${TODAY}"

  # Confirm the target index exists before touching the alias.
  local status
  status="$(_os_curl -o /dev/null -w '%{http_code}' "${BASE}/${target_index}")"
  if [[ "${status}" != "200" ]]; then
    log_warn "'${target_index}' not found (HTTP ${status}) — Logstash may not have written today's index yet. Re-run after midnight UTC when the first event arrives."
    return 0
  fi

  # Read where the alias currently points (single-index alias, so one line).
  local current
  current="$(_os_curl "${BASE}/_cat/aliases/${alias_name}?h=index" 2>/dev/null | tr -d '[:space:]')"

  if [[ "${current}" == "${target_index}" ]]; then
    log_info "OK — '${alias_name}' already → '${target_index}' (no-op)"
    return 0
  fi

  log_info "Rotating '${alias_name}': '${current:-<none>}' → '${target_index}'"

  if ${DRY_RUN}; then
    log_info "DRY-RUN: would POST _aliases { remove: ${current:-<none>}, add: ${target_index} }"
    return 0
  fi

  # Build atomic _aliases action: remove old (if any) then add new.
  local remove_part=""
  if [[ -n "${current}" ]]; then
    remove_part="{\"remove\":{\"index\":\"${current}\",\"alias\":\"${alias_name}\"}},"
  fi

  local http_code
  http_code="$(_os_curl -o /dev/null -w '%{http_code}' \
    -X POST "${BASE}/_aliases" \
    -H 'Content-Type: application/json' \
    -d "{\"actions\":[${remove_part}{\"add\":{\"index\":\"${target_index}\",\"alias\":\"${alias_name}\"}}]}")"

  if [[ "${http_code}" == "200" ]]; then
    log_info "OK — '${alias_name}' → '${target_index}' (HTTP 200)"
  else
    log_die "Failed to rotate '${alias_name}' → '${target_index}' (HTTP ${http_code})"
  fi
}

# Alias → index-prefix pairs. Add entries here when a new detector log type lands.
rotate_alias "suru-zeek-current"     "suru-zeek"
rotate_alias "suru-suricata-current" "suru-suricata"

log_info "=== SA alias rotation complete ==="
