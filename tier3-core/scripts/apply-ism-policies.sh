#!/bin/sh
# =============================================================================
# SURU Platform — Tier 3 Core  ·  apply-ism-policies.sh
# =============================================================================
# Purpose : Apply OpenSearch ISM (Index State Management) policies from
#           POLICIES_DIR via the ISM REST API. Idempotent — safe to re-run.
# Runtime : POSIX sh (Alpine / curlimages/curl); no bash required.
# Usage   : Called from tier3-core/scripts/deploy.sh on each full deploy
#           (when OpenSearch is healthy). Can also be run standalone:
#             bash tier3-core/scripts/apply-ism-policies.sh
# =============================================================================
set -eu

_ts()       { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_info()  { printf '[%s] [INFO]  %s\n'  "$(_ts)" "$*"; }
log_warn()  { printf '[%s] [WARN]  %s\n'  "$(_ts)" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n'  "$(_ts)" "$*" >&2; }
log_die()   { log_error "$*"; exit 1; }

# ── Required env ─────────────────────────────────────────────────────────────

: "${OPENSEARCH_INITIAL_ADMIN_PASSWORD:?OPENSEARCH_INITIAL_ADMIN_PASSWORD must be set}"
PASS="$OPENSEARCH_INITIAL_ADMIN_PASSWORD"

# ── Optional env with defaults ───────────────────────────────────────────────

OS_USER="${OS_USER:-admin}"
OS_HOST="${OS_HOST:-suru-t3-datalake-opensearch}"
OS_PORT="${OS_PORT:-9200}"
POLICIES_DIR="${POLICIES_DIR:-/config/ism-policies}"
MAX_RETRIES="${MAX_RETRIES:-10}"
RETRY_DELAY="${RETRY_DELAY:-15}"

# ── Dependency check ─────────────────────────────────────────────────────────

command -v curl   >/dev/null 2>&1 || log_die "curl is required but not found"
command -v awk    >/dev/null 2>&1 || log_die "awk is required but not found"
command -v sed    >/dev/null 2>&1 || log_die "sed is required but not found"
command -v mktemp >/dev/null 2>&1 || log_die "mktemp is required but not found"

# ── wait_for_opensearch ───────────────────────────────────────────────────────

wait_for_opensearch() {
  _attempt=0
  while [ "$_attempt" -lt "$MAX_RETRIES" ]; do
    _attempt=$(( _attempt + 1 ))
    log_info "Waiting for OpenSearch (attempt ${_attempt}/${MAX_RETRIES}) …"
    _status=$(curl -sk -u "${OS_USER}:${PASS}" \
      "https://${OS_HOST}:${OS_PORT}/_cluster/health?pretty" \
      --connect-timeout 5 --max-time 10 \
      | awk -F'"' '/"status"/{print $4; exit}') || true
    case "$_status" in
      green|yellow)
        log_info "OpenSearch is ready (status: ${_status})"
        return 0
        ;;
      *)
        log_warn "OpenSearch not ready yet (status: '${_status}'); retrying in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
        ;;
    esac
  done
  log_die "OpenSearch did not become ready after ${MAX_RETRIES} retries"
}

# ── apply_policy ──────────────────────────────────────────────────────────────
# Upserts an ISM policy from a file.
# File format (same as index templates):
#   # comment lines…
#   PUT /_plugins/_ism/policies/<policy_id>
#   { …JSON body… }

apply_policy() {
  _file="$1"

  _endpoint=$(grep -m1 '^PUT /' -- "$_file" | awk '{print $2}') || true
  if [ -z "$_endpoint" ]; then
    log_warn "No PUT endpoint found in '${_file}' — skipping"
    return 0
  fi

  _policy_id="${_endpoint##*/}"

  _body=$(sed -n '/^{/,$p' -- "$_file") || true
  if [ -z "$_body" ]; then
    log_warn "No JSON body found in '${_file}' — skipping"
    return 0
  fi

  _tmpfile=$(mktemp) || log_die "mktemp failed"
  printf '%s\n' "$_body" > "$_tmpfile"

  log_info "Applying: ${_file} → PUT ${_endpoint}"

  # Check if the policy already exists and fetch seq_no/primary_term in one call.
  _get_tmp=$(mktemp) || log_die "mktemp failed"
  _existing=$(curl -sk -u "${OS_USER}:${PASS}" \
    "https://${OS_HOST}:${OS_PORT}${_endpoint}" \
    -o "$_get_tmp" -w '%{http_code}') || true

  if [ "$_existing" = "200" ]; then
    _seq_no=$(awk -F'[:,]' '/"_seq_no"/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$_get_tmp") || true
    _primary_term=$(awk -F'[:,]' '/"_primary_term"/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$_get_tmp") || true
    rm -f "$_get_tmp"
    if [ -n "$_seq_no" ] && [ -n "$_primary_term" ]; then
      _url="https://${OS_HOST}:${OS_PORT}${_endpoint}?if_seq_no=${_seq_no}&if_primary_term=${_primary_term}"
      log_info "Policy '${_policy_id}' exists — updating (seq_no=${_seq_no}, primary_term=${_primary_term})"
    else
      _url="https://${OS_HOST}:${OS_PORT}${_endpoint}"
      log_warn "Could not retrieve seq_no/primary_term for '${_policy_id}' — attempting blind overwrite"
    fi
  elif [ "$_existing" = "401" ]; then
    rm -f "$_get_tmp"
    log_die "Unauthorized (HTTP 401) checking policy '${_policy_id}' — check OS_USER/OPENSEARCH_INITIAL_ADMIN_PASSWORD"
  else
    rm -f "$_get_tmp"
    _url="https://${OS_HOST}:${OS_PORT}${_endpoint}"
    log_info "Policy '${_policy_id}' does not exist — creating"
  fi

  _http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
    -X PUT -u "${OS_USER}:${PASS}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${_tmpfile}" \
    "$_url") || true

  rm -f -- "$_tmpfile"

  case "$_http_code" in
    200|201) log_info "OK — policy applied (HTTP ${_http_code}): ${_policy_id}" ;;
    401)     log_die "Unauthorized (HTTP 401) applying policy: ${_policy_id} — check OS_USER/OPENSEARCH_INITIAL_ADMIN_PASSWORD" ;;
    5*)      log_die "Server error (HTTP ${_http_code}) applying policy: ${_policy_id}" ;;
    *)       log_warn "Unexpected response (HTTP ${_http_code}) applying policy: ${_policy_id}" ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  log_info "=== SURU ISM policy init starting ==="
  log_info "OpenSearch target  : https://${OS_HOST}:${OS_PORT}"
  log_info "Policies directory : ${POLICIES_DIR}"

  wait_for_opensearch

  _found=0
  for _f in "${POLICIES_DIR}"/*.json; do
    [ -f "$_f" ] || continue
    apply_policy "$_f"
    _found=$(( _found + 1 ))
  done

  if [ "$_found" -eq 0 ]; then
    log_warn "No policy files found in '${POLICIES_DIR}'"
  else
    log_info "=== Applied ${_found} policy/policies — init complete ==="
  fi
}

main "$@"
