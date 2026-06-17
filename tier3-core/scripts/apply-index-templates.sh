#!/bin/sh
# =============================================================================
# SURU Platform — Tier 3 Core  ·  apply-index-templates.sh
# =============================================================================
# Purpose : Apply OpenSearch index templates from TEMPLATES_DIR via REST API.
# Runtime : POSIX sh (Alpine / curlimages/curl); no bash required.
# Container: suru.t3.datalake.template-init (one-shot init container)
# Volume  : opensearch-config mounted at /config; templates at
#           /config/index-templates/*.json
# =============================================================================
set -eu

# ── Log helpers ──────────────────────────────────────────────────────────────

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

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
TEMPLATES_DIR="${TEMPLATES_DIR:-/config/index-templates}"
MAX_RETRIES="${MAX_RETRIES:-10}"
RETRY_DELAY="${RETRY_DELAY:-15}"

# ── Dependency check ─────────────────────────────────────────────────────────

command -v curl  >/dev/null 2>&1 || log_die "curl is required but not found"
command -v awk   >/dev/null 2>&1 || log_die "awk is required but not found"
command -v sed   >/dev/null 2>&1 || log_die "sed is required but not found"
command -v mktemp >/dev/null 2>&1 || log_die "mktemp is required but not found"

# ── wait_for_opensearch ───────────────────────────────────────────────────────
# Poll GET /_cluster/health until status is green or yellow, up to
# MAX_RETRIES attempts spaced RETRY_DELAY seconds apart.

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

# ── apply_template ────────────────────────────────────────────────────────────
# Extract the PUT endpoint and JSON body from a template file, then PUT it to
# the OpenSearch REST API.
#
# Template file format:
#   # comment lines …
#   PUT /_index_template/<name>
#   {
#     …JSON body…
#   }

apply_template() {
  _file="$1"

  # Extract the API endpoint: first line matching ^PUT /
  _endpoint=$(grep -m1 '^PUT /' -- "$_file" | awk '{print $2}') || true

  if [ -z "$_endpoint" ]; then
    log_warn "No PUT endpoint found in '${_file}' — skipping"
    return 0
  fi

  # Extract JSON body: everything from the first { line to EOF
  _body=$(sed -n '/^{/,$p' -- "$_file") || true

  if [ -z "$_body" ]; then
    log_warn "No JSON body found in '${_file}' — skipping"
    return 0
  fi

  # Write body to a temp file to avoid quoting issues with large JSON blobs
  _tmpfile=$(mktemp) || log_die "mktemp failed — ensure tmpfs:/tmp is mounted (container uses read_only:true)"
  printf '%s\n' "$_body" > "$_tmpfile"

  log_info "Applying: ${_file} → PUT ${_endpoint}"

  _http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
    -X PUT -u "${OS_USER}:${PASS}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${_tmpfile}" \
    "https://${OS_HOST}:${OS_PORT}${_endpoint}") || true

  rm -f -- "$_tmpfile"

  case "$_http_code" in
    200|201) log_info "OK — template applied (HTTP ${_http_code}): ${_endpoint}" ;;
    401)     log_die "Unauthorized (HTTP 401) applying template: ${_endpoint} — check OS_USER/OPENSEARCH_INITIAL_ADMIN_PASSWORD" ;;
    5*)      log_die "Server error (HTTP ${_http_code}) applying template: ${_endpoint}" ;;
    *)       log_warn "Unexpected response (HTTP ${_http_code}) applying template: ${_endpoint}" ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  log_info "=== SURU index-template init starting ==="
  log_info "OpenSearch target : https://${OS_HOST}:${OS_PORT}"
  log_info "Templates directory: ${TEMPLATES_DIR}"

  wait_for_opensearch

  _found=0

  for _f in "${TEMPLATES_DIR}"/*.json; do
    # Skip glob literal when no files match
    [ -f "$_f" ] || continue

    apply_template "$_f"
    _found=$(( _found + 1 ))
  done

  if [ "$_found" -eq 0 ]; then
    log_warn "No template files found in '${TEMPLATES_DIR}'"
  else
    log_info "=== Applied ${_found} template(s) — init complete ==="
  fi
}

main "$@"
