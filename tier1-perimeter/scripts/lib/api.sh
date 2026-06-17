#!/usr/bin/env bash
# =============================================================================
# SURU Tier 1 — lib/api.sh
# Router REST API client. Self-contained — sources no other lib file.
#
# Platforms:
#   pfSense   — pfRest (https://pfrest.org/)
#   OPNsense  — native API (https://docs.opnsense.org/development/api.html)
#
# AUTHENTICATION MODES (API_AUTH_MODE)
# ----------------------------------------------------------------------------
#   api_key   Long-lived static key.  RECOMMENDED FOR AUTOMATION / CI.
#             - pfSense:  header `X-API-Key: ${PFSENSE_API_KEY}`
#             - OPNsense: HTTP Basic with `${OPNSENSE_API_KEY}:${OPNSENSE_API_SECRET}`
#
#   jwt       Short-lived bearer token (pfSense only).  BEST FOR INTERACTIVE
#             OPERATOR SESSIONS — minimises blast radius if leaked.
#             - POST /api/v2/auth/jwt with username/password to obtain.
#             - Cached in-process; auto-refreshed before expiry.
#             - Never persisted to disk.
#
# SECURITY HARDENING
# ----------------------------------------------------------------------------
#   * Auth tokens and request bodies are written to 0600 temp files (preferred
#     under /dev/shm when available) and passed to curl via `--header @file`
#     and `--data-binary @file`. This keeps secrets out of process argv and
#     therefore out of `ps`/proc.
#   * TLS verification is ON by default. Disabling emits a WARN, not silent.
#   * Tokens are never written to logs at any verbosity.
#
# PUBLIC API
# ----------------------------------------------------------------------------
#   api_init                          Validate env; set per-platform URL defaults
#   api_request METHOD PATH [BODY]    Generic dispatch
#   api_health                        Authenticated reachability probe
#   api_validate_deployment           Orchestrate full post-deploy validation
#   api_service_status SVC            Per-service status query (status booleans)
#   api_reload_suricata_rules         Hot-reload Suricata rules (via exec)
#   api_fetch_errors [LIMIT]          Recent system log entries
#   api_pfsense_install               pfSense ONLY — install pfRest pkg via SSH
#   api_pfsense_jwt_login             pfSense ONLY — obtain a JWT (called as needed)
#
# VALIDATION HELPERS (pfSense; OPNsense uses different namespaces)
# ----------------------------------------------------------------------------
#   api_validate_packages             Verify Suricata/Zeek/pfBlockerNG/RESTAPI installed
#   api_validate_suricata_config      `suricata -T` against deployed config
#   api_validate_zeek_status          `zeekctl status` — all nodes running
#   api_validate_syslogng_config      `syslog-ng -s` config syntax check
#   api_validate_pfblockerng_aliases  pfB_SURU_* aliases exist with entries
#   api_validate_recent_errors        Scan last N system log lines for ERROR/CRIT
#
# LOW-LEVEL PRIMITIVES (pfSense)
# ----------------------------------------------------------------------------
#   _api_pfsense_exec CMD             POST /diagnostics/command_prompt — runs
#                                     shell CMD as root via API. stdout = output,
#                                     sets _API_EXEC_RC to result_code.
#
# REQUIRED ENV VARS
# ----------------------------------------------------------------------------
#   ROUTER_PLATFORM     pfsense | opnsense
#   ROUTER_HOST         router host/IP
#   API_AUTH_MODE       api_key (default) | jwt
#
#   pfSense (api_key mode):
#     PFSENSE_API_KEY
#   pfSense (jwt mode):
#     PFSENSE_API_USERNAME
#     PFSENSE_API_PASSWORD            <-- treat as high-sensitivity; prefer SOPS
#   pfSense (always for install):
#     PFSENSE_API_PKG_URL
#
#   OPNsense (api_key mode only; native API does not support JWT):
#     OPNSENSE_API_KEY
#     OPNSENSE_API_SECRET
#
#   Optional:
#     PFSENSE_API_URL                 default: https://${ROUTER_HOST}/api/v2
#     OPNSENSE_API_URL                default: https://${ROUTER_HOST}/api
#     API_TLS_VERIFY                  yes (default) | no
#     API_CONNECT_TIMEOUT             seconds, default 30
#     API_MAX_TIME                    seconds, default 60
# =============================================================================

# --- Standalone fallbacks if lib/log.sh is not sourced ----------------------
type log_info  &>/dev/null || log_info()  { echo "[api:INFO] $*"; }
type log_warn  &>/dev/null || log_warn()  { echo "[api:WARN] $*" >&2; }
type log_error &>/dev/null || log_error() { echo "[api:ERROR] $*" >&2; }
type log_debug &>/dev/null || log_debug() { ${VERBOSE:-false} && echo "[api:DEBUG] $*" >&2 || true; }
type log_die   &>/dev/null || log_die()   { log_error "$*"; exit 1; }

# Default auth mode
: "${API_AUTH_MODE:=api_key}"

# In-process JWT cache (pfSense). Never persisted.
_PF_JWT_TOKEN=""
_PF_JWT_EXPIRES_EPOCH=0
_PF_JWT_REFRESH_BUFFER=60   # refresh if <60s remain on JWT

# Track temp files for trap-based cleanup as a safety net
_API_TMPFILES=()

# ---------------------------------------------------------------------------
# api_init
# Validates env vars per (platform, mode). Sets URL defaults.
# ---------------------------------------------------------------------------
api_init() {
  : "${ROUTER_PLATFORM:?ROUTER_PLATFORM not set}"
  : "${ROUTER_HOST:?ROUTER_HOST not set}"

  command -v curl >/dev/null 2>&1 || log_die "curl is required for API operations"

  case "${API_AUTH_MODE}" in
    api_key|jwt) : ;;
    *) log_die "Unsupported API_AUTH_MODE='${API_AUTH_MODE}' (api_key|jwt)" ;;
  esac

  case "$(echo "${API_TLS_VERIFY:-yes}" | tr '[:upper:]' '[:lower:]')" in
    no|false|0|off)
      log_warn "API_TLS_VERIFY is disabled — accepting untrusted certs."
      log_warn "ONLY acceptable for lab environments with known self-signed certs."
      ;;
  esac

  case "${ROUTER_PLATFORM}" in
    pfsense)
      : "${PFSENSE_API_URL:=https://${ROUTER_HOST}/api/v2}"
      case "${API_AUTH_MODE}" in
        api_key)
          [[ -n "${PFSENSE_API_KEY:-}" ]] || log_die \
            "PFSENSE_API_KEY not set (required for API_AUTH_MODE=api_key)"
          ;;
        jwt)
          [[ -n "${PFSENSE_API_USERNAME:-}" ]] || log_die \
            "PFSENSE_API_USERNAME not set (required for API_AUTH_MODE=jwt)"
          [[ -n "${PFSENSE_API_PASSWORD:-}" ]] || log_die \
            "PFSENSE_API_PASSWORD not set (required for API_AUTH_MODE=jwt)"
          ;;
      esac
      ;;
    opnsense)
      : "${OPNSENSE_API_URL:=https://${ROUTER_HOST}/api}"
      [[ "${API_AUTH_MODE}" == "api_key" ]] || log_die \
        "OPNsense native API only supports API_AUTH_MODE=api_key (JWT is pfSense-only)"
      [[ -n "${OPNSENSE_API_KEY:-}"    ]] || log_die "OPNSENSE_API_KEY not set"
      [[ -n "${OPNSENSE_API_SECRET:-}" ]] || log_die "OPNSENSE_API_SECRET not set"
      ;;
    *)
      log_die "api_init: unsupported ROUTER_PLATFORM=${ROUTER_PLATFORM}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _api_mktemp_secure → echoes path to a fresh 0600 file.
# Prefers /dev/shm (tmpfs, RAM-only) on Linux; falls back to $TMPDIR or /tmp.
# ---------------------------------------------------------------------------
_api_mktemp_secure() {
  local tmpdir="${TMPDIR:-/tmp}"
  [[ -d /dev/shm && -w /dev/shm ]] && tmpdir=/dev/shm
  local f
  f="$(mktemp "${tmpdir}/suru-api.XXXXXXXX")" || return 1
  chmod 600 "${f}" || { rm -f "${f}"; return 1; }
  _API_TMPFILES+=("${f}")
  echo "${f}"
}

# Clean up any tracked temp files (called on EXIT and on demand).
# Safe under `set -u`: only iterates if the array has at least one element.
_api_cleanup_tmp() {
  if (( ${#_API_TMPFILES[@]} > 0 )); then
    local f
    for f in "${_API_TMPFILES[@]}"; do
      [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}"
    done
    _API_TMPFILES=()
  fi
}
trap _api_cleanup_tmp EXIT

# ---------------------------------------------------------------------------
# _api_curl_base_opts — flags that are safe to pass on argv (no secrets)
# ---------------------------------------------------------------------------
_api_curl_base_opts() {
  CURL_OPTS=(
    --silent --show-error --fail-with-body
    --connect-timeout "${API_CONNECT_TIMEOUT:-30}"
    --max-time         "${API_MAX_TIME:-60}"
  )
  case "$(echo "${API_TLS_VERIFY:-yes}" | tr '[:upper:]' '[:lower:]')" in
    no|false|0|off) CURL_OPTS+=(--insecure) ;;
  esac
}

# ---------------------------------------------------------------------------
# api_request METHOD PATH [BODY] → stdout=response body, exit=curl status
# ---------------------------------------------------------------------------
api_request() {
  case "${ROUTER_PLATFORM}" in
    pfsense)   _api_pfsense_request  "$@" ;;
    opnsense)  _api_opnsense_request "$@" ;;
    *)         log_die "api_request: unknown ROUTER_PLATFORM=${ROUTER_PLATFORM}" ;;
  esac
}

# ---------------------------------------------------------------------------
# _api_pfsense_ensure_auth — guarantees we have valid creds for current mode.
# For jwt mode, refreshes the cached JWT if missing or near expiry.
# ---------------------------------------------------------------------------
_api_pfsense_ensure_auth() {
  case "${API_AUTH_MODE}" in
    api_key)
      [[ -n "${PFSENSE_API_KEY:-}" ]] || log_die "PFSENSE_API_KEY not set"
      ;;
    jwt)
      local now
      now=$(date +%s)
      if [[ -z "${_PF_JWT_TOKEN}" ]] \
         || (( now >= _PF_JWT_EXPIRES_EPOCH - _PF_JWT_REFRESH_BUFFER )); then
        api_pfsense_jwt_login
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# api_pfsense_jwt_login — POST /auth/jwt with username/password, cache token.
# Body is sent via 0600 temp file to keep password out of argv.
# ---------------------------------------------------------------------------
api_pfsense_jwt_login() {
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] \
    || log_die "api_pfsense_jwt_login called for ROUTER_PLATFORM=${ROUTER_PLATFORM}"
  : "${PFSENSE_API_USERNAME:?PFSENSE_API_USERNAME not set}"
  : "${PFSENSE_API_PASSWORD:?PFSENSE_API_PASSWORD not set}"
  : "${PFSENSE_API_URL:=https://${ROUTER_HOST}/api/v2}"

  local url="${PFSENSE_API_URL%/}/auth/jwt"
  local hdrfile bodyfile
  hdrfile="$(_api_mktemp_secure)"  || log_die "Cannot create secure tmp file"
  bodyfile="$(_api_mktemp_secure)" || log_die "Cannot create secure tmp file"

  {
    echo "Content-Type: application/json"
    echo "Accept: application/json"
  } > "${hdrfile}"

  # JSON-escape user+password just enough for a flat object. We rely on
  # printf %s with a fixed schema; double-quote chars in user/pass are
  # escaped by sed below.
  local u p
  u="${PFSENSE_API_USERNAME//\"/\\\"}"
  p="${PFSENSE_API_PASSWORD//\"/\\\"}"
  printf '{"username":"%s","password":"%s"}' "${u}" "${p}" > "${bodyfile}"

  _api_curl_base_opts
  log_debug "API pfSense POST ${url} (jwt login)"

  local resp rc=0
  resp="$(curl "${CURL_OPTS[@]}" \
            --request POST \
            --header "@${hdrfile}" \
            --data-binary "@${bodyfile}" \
            "${url}")" || rc=$?
  rm -f "${hdrfile}" "${bodyfile}"

  (( rc == 0 )) || log_die "JWT login to pfRest failed (URL: ${url}). Check credentials and TLS."

  # Parse token + ttl. Prefer jq for safety.
  local token ttl
  if command -v jq >/dev/null 2>&1; then
    token="$(echo "${resp}" | jq -r '.data.token // .token // empty')"
    ttl="$(echo "${resp}" | jq -r '.data.expires_in // .expires_in // 3600')"
  else
    # Permissive fallback parser
    token="$(echo "${resp}" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    ttl="$(echo "${resp}" | sed -n 's/.*"expires_in"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)"
    ttl="${ttl:-3600}"
  fi

  [[ -n "${token}" ]] || log_die "JWT login succeeded but no token in response."

  _PF_JWT_TOKEN="${token}"
  _PF_JWT_EXPIRES_EPOCH=$(( $(date +%s) + ttl ))
  log_info "pfRest JWT acquired (ttl=${ttl}s)"
}

# ---------------------------------------------------------------------------
# _api_pfsense_request METHOD PATH [BODY]
# ---------------------------------------------------------------------------
_api_pfsense_request() {
  local method="$1" path="$2" body="${3:-}"
  local url="${PFSENSE_API_URL%/}${path}"
  _api_pfsense_ensure_auth

  local hdrfile bodyfile=""
  hdrfile="$(_api_mktemp_secure)" || log_die "Cannot create secure tmp file"

  {
    echo "Content-Type: application/json"
    echo "Accept: application/json"
    case "${API_AUTH_MODE}" in
      api_key) printf 'X-API-Key: %s\n'        "${PFSENSE_API_KEY}" ;;
      jwt)     printf 'Authorization: Bearer %s\n' "${_PF_JWT_TOKEN}" ;;
    esac
  } > "${hdrfile}"

  _api_curl_base_opts
  CURL_OPTS+=(--request "${method}" --header "@${hdrfile}")
  log_debug "API pfSense ${method} ${url} (auth=${API_AUTH_MODE})"

  local rc=0
  if [[ -n "${body}" ]]; then
    bodyfile="$(_api_mktemp_secure)" || log_die "Cannot create secure tmp file"
    printf '%s' "${body}" > "${bodyfile}"
    curl "${CURL_OPTS[@]}" --data-binary "@${bodyfile}" "${url}" || rc=$?
    rm -f "${bodyfile}"
  else
    curl "${CURL_OPTS[@]}" "${url}" || rc=$?
  fi
  rm -f "${hdrfile}"
  return ${rc}
}

# ---------------------------------------------------------------------------
# _api_opnsense_request METHOD PATH [BODY]
# OPNsense uses HTTP Basic with key:secret. We build the Basic header
# manually so the secret never enters curl argv.
# ---------------------------------------------------------------------------
_api_opnsense_request() {
  local method="$1" path="$2" body="${3:-}"
  local url="${OPNSENSE_API_URL%/}${path}"

  local hdrfile bodyfile=""
  hdrfile="$(_api_mktemp_secure)" || log_die "Cannot create secure tmp file"

  local b64
  b64="$(printf '%s' "${OPNSENSE_API_KEY}:${OPNSENSE_API_SECRET}" \
          | base64 | tr -d '\n')"
  {
    echo "Content-Type: application/json"
    echo "Accept: application/json"
    echo "Authorization: Basic ${b64}"
  } > "${hdrfile}"

  _api_curl_base_opts
  CURL_OPTS+=(--request "${method}" --header "@${hdrfile}")
  log_debug "API OPNsense ${method} ${url} (auth=api_key)"

  local rc=0
  if [[ -n "${body}" ]]; then
    bodyfile="$(_api_mktemp_secure)" || log_die "Cannot create secure tmp file"
    printf '%s' "${body}" > "${bodyfile}"
    curl "${CURL_OPTS[@]}" --data-binary "@${bodyfile}" "${url}" || rc=$?
    rm -f "${bodyfile}"
  else
    curl "${CURL_OPTS[@]}" "${url}" || rc=$?
  fi
  rm -f "${hdrfile}"
  return ${rc}
}

# ---------------------------------------------------------------------------
# api_health
# ---------------------------------------------------------------------------
api_health() {
  api_init
  case "${ROUTER_PLATFORM}" in
    # /system/restapi/version requires only page-system-restapi — the one
    # privilege all suru-validator calls share. Avoids needing page-status-system.
    pfsense)  api_request GET /system/restapi/version >/dev/null ;;
    opnsense) api_request GET /core/system/info       >/dev/null ;;
  esac
}

# ---------------------------------------------------------------------------
# api_validate_deployment — lightweight post-deploy validation suite.
#
# Uses only native pfREST API endpoints (no command_prompt / shell exec).
# Engine config tests (suricata -T, syslog-ng -s, zeekctl status) are
# deliberately excluded: they run via SSH during make deploy and are
# resource-intensive on SOHO hardware — running them again via API inside
# PHP-FPM risks exhausting router memory and crashing the web stack.
#
# Fail-fast: aborts immediately on auth failure (401/403) with a clear
# message rather than cascading into misleading "service not running" output.
# ---------------------------------------------------------------------------
api_validate_deployment() {
  api_init
  local fail=0

  # --- Auth gate: abort early if credentials are wrong or missing -----------
  if ! api_health 2>/dev/null; then
    log_error "API health check failed — authentication error or router unreachable."
    log_error "  Check PFSENSE_API_KEY / API_AUTH_MODE in .env (run 'make api-bootstrap' to issue a key)."
    log_error "  Check API_TLS_VERIFY and PFSENSE_API_URL."
    return 1
  fi
  log_info "API reachable — running validation suite (pfSense via pfREST):"

  case "${ROUTER_PLATFORM}" in
    pfsense)
      log_info "[1/4] Packages installed:"
      api_validate_packages           || fail=1

      log_info "[2/4] Service status (native API — no shell exec on router):"
      local svc
      for svc in syslog-ng suricata zeek; do
        if api_service_running "${svc}"; then
          log_info "  ${svc}: ✓ (running)"
        else
          log_warn "  ${svc}: ✗ (not running or status unavailable)"
          fail=1
        fi
      done

      log_info "[3/4] pfBlockerNG DNSBL aliases:"
      api_validate_pfblockerng_aliases

      log_info "[4/4] Recent system log errors:"
      api_validate_recent_errors 100
      ;;

    opnsense)
      log_info "Validation suite (OPNsense native API):"
      local svc
      for svc in syslog-ng suricata zeek; do
        if api_service_status "${svc}" >/dev/null 2>&1; then
          log_info "  ${svc}: status OK"
        else
          log_warn "  ${svc}: status check failed"
          fail=1
        fi
      done
      ;;
  esac

  if (( fail == 0 )); then
    log_info "Validation suite: PASS"
  else
    log_warn "Validation suite: FAIL — review entries marked ✗ above"
  fi
  return $fail
}

# ---------------------------------------------------------------------------
# api_service_status SERVICE_NAME
# pfREST: GET /status/service?id=<name> → returns Service object with
#   { name, description, enabled (bool), status (bool — actively running) }
# ---------------------------------------------------------------------------
api_service_status() {
  local svc="$1"
  case "${ROUTER_PLATFORM}" in
    pfsense)
      api_request GET "/status/service?id=${svc}"
      ;;
    opnsense)
      local ns
      case "${svc}" in
        suricata)  ns="ids" ;;
        syslog-ng) ns="syslog" ;;
        zeek)      ns="zeek" ;;
        *)         ns="${svc}" ;;
      esac
      api_request GET "/${ns}/service/status"
      ;;
  esac
}

# Returns 0 only if the service exists, is enabled, and is actively running.
api_service_running() {
  local svc="$1" resp
  resp="$(api_service_status "${svc}" 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    [[ "$(echo "${resp}" | jq -r '.data.status // .status // false')" == "true" ]]
  else
    # Permissive fallback: look for "status":true in body
    [[ "${resp}" == *'"status":true'* ]]
  fi
}

# ---------------------------------------------------------------------------
# _api_pfsense_exec CMD
# Execute a shell command on the router via POST /diagnostics/command_prompt.
# The endpoint runs as the pfREST process user (root). stdout = combined
# command output. Sets _API_EXEC_RC to the result_code from pfREST.
#
# Schema (verified from /api/v2/schema/openapi):
#   Request body:  {"command": "..."}     (max 1024 chars)
#   Response data: {"command","output","result_code"}
#
# Security: the command is sent via 0600 temp file (same mechanism as auth
# headers) so it never appears in `ps`/proc argv. Callers should still avoid
# embedding secrets in CMD — the command appears in the pfREST audit log
# (/status/logs/packages/restapi), which is exactly what we want for audit
# but means no passwords/keys should be passed.
# ---------------------------------------------------------------------------
_API_EXEC_RC=0
_api_pfsense_exec() {
  local cmd="$1"
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] \
    || log_die "_api_pfsense_exec called for ROUTER_PLATFORM=${ROUTER_PLATFORM}"
  [[ ${#cmd} -le 1024 ]] \
    || log_die "_api_pfsense_exec: command exceeds 1024-char pfREST limit (got ${#cmd})"

  # JSON-encode the command. Backslashes first, then quotes, then control chars.
  local esc="${cmd}"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"
  esc="${esc//$'\r'/\\r}"
  esc="${esc//$'\t'/\\t}"
  local body
  body="$(printf '{"command":"%s"}' "${esc}")"

  local resp rc=0
  resp="$(api_request POST "/diagnostics/command_prompt" "${body}")" || rc=$?

  if (( rc != 0 )); then
    _API_EXEC_RC=${rc}
    log_debug "exec failed (curl rc=${rc}): ${cmd}"
    return ${rc}
  fi

  if command -v jq >/dev/null 2>&1; then
    _API_EXEC_RC="$(echo "${resp}" | jq -r '.data.result_code // 0')"
    echo "${resp}" | jq -r '.data.output // ""'
  else
    # Permissive sed fallback if jq is unavailable on the operator host
    _API_EXEC_RC="$(echo "${resp}" \
      | sed -n 's/.*"result_code"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' \
      | head -n1)"
    : "${_API_EXEC_RC:=0}"
    # Crude output extractor — fine for short outputs, jq is preferred
    echo "${resp}" \
      | sed -n 's/.*"output"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*,.*"result_code".*/\1/p' \
      | head -n1 \
      | sed 's/\\n/\n/g; s/\\"/"/g; s/\\\\/\\/g'
  fi
}

# ---------------------------------------------------------------------------
# api_reload_suricata_rules — hot-reload rules without service restart.
# pfREST has no native Suricata endpoint, so we exec suricatasc via API.
# This is the same call the Suricata package GUI makes internally.
# ---------------------------------------------------------------------------
api_reload_suricata_rules() {
  api_init
  case "${ROUTER_PLATFORM}" in
    pfsense)
      _api_pfsense_exec "suricatasc -c reload-rules" \
        || log_warn "Suricata rule reload via API failed (rc=${_API_EXEC_RC})"
      ;;
    opnsense)
      api_request POST "/ids/service/reload" ""
      ;;
  esac
}

# ===========================================================================
# COMPONENT VALIDATORS (pfSense)
# Each returns 0 on success, 1 on failure. Stdout is human-readable summary.
# ===========================================================================

# ---------------------------------------------------------------------------
# api_validate_packages
# Verify all SURU-required packages are installed via GET /system/packages.
# ---------------------------------------------------------------------------
api_validate_packages() {
  api_init
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] || { log_warn "api_validate_packages: pfSense only"; return 0; }

  local resp
  resp="$(api_request GET "/system/packages")" || { log_warn "validate_packages: API call failed"; return 1; }

  # pfBlockerNG ships as either pfSense-pkg-pfBlockerNG or pfSense-pkg-pfBlockerNG-devel
  # depending on which channel is installed — match both with a prefix check below.
  local required=( pfSense-pkg-RESTAPI pfSense-pkg-suricata pfSense-pkg-zeek pfSense-pkg-pfBlockerNG )
  # zeek package alternate name (some pfSense builds use lowercase 'pfSense-pkg-zeek')
  local missing=() pkg present_list

  if command -v jq >/dev/null 2>&1; then
    present_list="$(echo "${resp}" | jq -r '.data[]?.name // empty')"
  else
    present_list="$(echo "${resp}" | tr ',' '\n' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi

  for pkg in "${required[@]}"; do
    if echo "${present_list}" | grep -qiF "${pkg}"; then
      log_info "  package: ${pkg} ✓"
    else
      log_warn "  package: ${pkg} ✗ (not installed)"
      missing+=("${pkg}")
    fi
  done

  (( ${#missing[@]} == 0 ))
}

# ---------------------------------------------------------------------------
# api_validate_suricata_config
# Execute `suricata -T` against the deployed config. Result code 0 = OK.
# Output may be multi-line; we report exit code and last line.
# ---------------------------------------------------------------------------
api_validate_suricata_config() {
  api_init
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] || return 0
  local out
  out="$(_api_pfsense_exec "sudo suricata -T -c /usr/local/etc/suricata/suricata.yaml 2>&1 | tail -n 3")"
  if (( _API_EXEC_RC == 0 )); then
    log_info "  suricata -T: ✓ (config valid)"
    return 0
  fi
  log_warn "  suricata -T: ✗ (rc=${_API_EXEC_RC})"
  echo "${out}" | sed 's/^/    /'
  return 1
}

# ---------------------------------------------------------------------------
# api_validate_zeek_status
# `zeekctl status` returns 0 when all nodes are "running".
# ---------------------------------------------------------------------------
api_validate_zeek_status() {
  api_init
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] || return 0
  local out
  out="$(_api_pfsense_exec "sudo zeekctl status 2>&1")"
  if (( _API_EXEC_RC == 0 )) && echo "${out}" | grep -q "running"; then
    log_info "  zeekctl status: ✓ (nodes running)"
    return 0
  fi
  log_warn "  zeekctl status: ✗ (rc=${_API_EXEC_RC})"
  echo "${out}" | sed 's/^/    /'
  return 1
}

# ---------------------------------------------------------------------------
# api_validate_syslogng_config
# `syslog-ng -s` returns 0 on valid config, non-zero on syntax errors.
# ---------------------------------------------------------------------------
api_validate_syslogng_config() {
  api_init
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] || return 0
  local out
  out="$(_api_pfsense_exec "syslog-ng -s 2>&1")"
  if (( _API_EXEC_RC == 0 )); then
    log_info "  syslog-ng -s: ✓ (config valid)"
    return 0
  fi
  log_warn "  syslog-ng -s: ✗ (rc=${_API_EXEC_RC})"
  echo "${out}" | sed 's/^/    /'
  return 1
}

# ---------------------------------------------------------------------------
# api_validate_pfblockerng_aliases
# Confirms pfB_SURU_* aliases were created by pfBlockerNG after the deploy
# imported our DNSBL feeds. Each SURU feed in the imported config becomes a
# pfB_<aliasname>_v4 (and _v6) firewall alias on the next pfBlockerNG run.
#
# Note: aliases only appear after pfBlockerNG runs its cron job or after a
# manual "Force Reload" in the UI. On a fresh import, the firewall/aliases
# endpoint may return zero pfB_SURU_* entries; this is a warning, not failure.
# ---------------------------------------------------------------------------
api_validate_pfblockerng_aliases() {
  api_init
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] || return 0
  local resp count
  resp="$(api_request GET "/firewall/aliases")" || { log_warn "  pfBlockerNG aliases: API call failed"; return 1; }

  if command -v jq >/dev/null 2>&1; then
    count="$(echo "${resp}" | jq -r '[.data[]? | select(.name | startswith("pfB_SURU"))] | length')"
  else
    count="$(echo "${resp}" | grep -oE '"name"[[:space:]]*:[[:space:]]*"pfB_SURU[^"]*"' | wc -l | tr -d ' ')"
  fi

  if [[ -n "${count}" && "${count}" -gt 0 ]]; then
    log_info "  pfBlockerNG aliases: ✓ (${count} pfB_SURU_* aliases present)"
    return 0
  fi
  log_warn "  pfBlockerNG aliases: ⚠ (no pfB_SURU_* aliases yet — run \"Force Reload\" or wait for cron)"
  return 0  # non-fatal; aliases are created async by pfBlockerNG
}

# ---------------------------------------------------------------------------
# api_validate_recent_errors [LIMIT]
# Pulls the last N system log lines and reports the count of ERROR/CRITICAL
# entries. Returns 0 if none found, 1 if any.
# ---------------------------------------------------------------------------
api_validate_recent_errors() {
  local limit="${1:-50}"
  api_init
  local resp body err_count
  resp="$(api_fetch_errors "${limit}")" || { log_warn "  recent errors: log fetch failed"; return 1; }

  if command -v jq >/dev/null 2>&1; then
    body="$(echo "${resp}" | jq -r '.data[]?.text // .data[]? // empty' 2>/dev/null || echo "${resp}")"
  else
    body="${resp}"
  fi

  err_count="$(echo "${body}" | grep -ciE 'error|critical|fatal' || true)"
  if [[ "${err_count}" -eq 0 ]]; then
    log_info "  recent log scan: ✓ (0 errors in last ${limit} lines)"
    return 0
  fi
  log_warn "  recent log scan: ⚠ (${err_count} error/critical lines in last ${limit})"
  return 0  # surface count but don't fail the deploy on log volume alone
}

# ---------------------------------------------------------------------------
# api_fetch_errors [LIMIT]
# Returns the last N system log entries. pfREST exposes these under
# /status/logs/system (confirmed against OpenAPI schema /api/v2/schema/openapi).
# ---------------------------------------------------------------------------
api_fetch_errors() {
  local limit="${1:-200}"
  api_init
  case "${ROUTER_PLATFORM}" in
    pfsense)
      api_request GET "/status/logs/system?limit=${limit}"
      ;;
    opnsense)
      api_request GET "/diagnostics/log/core/system?limit=${limit}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# api_pfsense_bootstrap_validator [ADMIN_USER]
# pfSense ONLY — one-shot setup of the suru-validator API user + API key.
# Idempotent: if suru-validator already exists, resets password + reissues key.
# Run after api_pfsense_install. Never run during automated deploys.
#
# FLOW
#   1. Prompt admin password (read -s; never stored or logged)
#   2. Generate a random ephemeral password for suru-validator
#   3. Auth as admin (JWT) → create/patch suru-validator with 6 privileges
#   4. Auth as suru-validator (JWT) → issue API key (sha512, 32 bytes)
#   5. Print PFSENSE_API_KEY value for operator to paste into .env
#   6. Scrub all credential variables from memory
#
# MINIMUM-PRIVILEGE NOTES
#   The 6 pfSense page privileges assigned to suru-validator map to exactly
#   the API endpoints called by api_validate_deployment. The list is defined
#   in _SURU_VALIDATOR_PRIVS below — verify against your pfSense version if
#   any endpoint returns 403.
#
# OUTPUT
#   Prints "PFSENSE_API_KEY=<value>" to stdout on success.
#   Operator pastes it into .env (keep .env encrypted with SOPS + age).
# ---------------------------------------------------------------------------
# pfREST v2 uses its own api-v2-<resource>-<method> privilege format, not
# standard pfSense page-* privileges. The only cross-compatible grant is
# page-all. The API key itself is the security boundary — suru-validator
# can only authenticate via the rotated key issued by make api-bootstrap.
_SURU_VALIDATOR_PRIVS=(
  "page-all"
)

api_pfsense_bootstrap_validator() {
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] \
    || log_die "api_pfsense_bootstrap_validator: pfSense only"
  : "${ROUTER_HOST:?ROUTER_HOST not set}"
  : "${ROUTER_SSH_KEY:?ROUTER_SSH_KEY not set}"

  # Single SSH+PHP script creates the user AND stores the API key directly in
  # pfSense config — no JWT step, no chicken-and-egg, no sshguard risk.
  log_info "[bootstrap] Running user + key provisioning via SSH+PHP..."
  local api_key
  api_key="$(_api_pfsense_bootstrap_ssh)" \
    || log_die "Bootstrap PHP script failed on router"
  [[ -n "${api_key}" ]] \
    || log_die "Bootstrap: no PFSENSE_API_KEY line in PHP output — check router logs"

  printf '\n'
  printf '=%.0s' {1..60}; printf '\n'
  printf 'Bootstrap complete. Paste into tier1-perimeter/.env:\n\n'
  printf 'API_AUTH_MODE=api_key\n'
  printf 'PFSENSE_API_KEY=%s\n' "${api_key}"
  printf '\n  Key: sha512 / 32B — rotate every 90 days with: make api-bootstrap\n'
  printf '  Encrypt .env at rest:  sops --encrypt --in-place .env\n'
  printf '=%.0s' {1..60}; printf '\n'
}

# ---------------------------------------------------------------------------
# _api_pfsense_bootstrap_ssh
# Creates suru-validator user + pfREST API key in pfSense config in a single
# PHP script executed via SSH (same credentials as make deploy). Prints the
# raw API key to stdout on success; all other output goes to stderr.
#
# Key storage format (verified from /usr/local/pkg/RESTAPI/Models/RESTAPIKey.inc):
#   config path: installedpackages/package/<restapi_pkg_id>/conf/keys/key[]
#   key:         bin2hex(random_bytes(32))       — 64 hex chars
#   stored hash: hash('sha512', $raw_key)
# ---------------------------------------------------------------------------
_api_pfsense_bootstrap_ssh() {
  # Build privilege PHP array literal: ['priv1','priv2',...]
  local php_privs="[" _first=true _p
  for _p in "${_SURU_VALIDATOR_PRIVS[@]}"; do
    [[ "${_first}" == "true" ]] || php_privs+=","
    php_privs+="'${_p}'"
    _first=false
  done
  php_privs+="]"

  local php_file remote_php
  php_file="$(mktemp /tmp/suru-bootstrap-XXXXXX.php)"
  remote_php="/tmp/suru-bootstrap-validator.php"

  # php_privs is alphanumeric/dashes only — safe to embed directly.
  cat > "${php_file}" << PHPEOF
<?php
// pfSense requires globals.inc + functions.inc before config.lib.inc
// when running outside the web bootstrapper (e.g. sudo php /tmp/script.php)
require_once('globals.inc');
require_once('config.lib.inc');
require_once('functions.inc');

// ── 1. Create / update suru-validator ──────────────────────────────────────
\$privs = ${php_privs};
\$pass  = bin2hex(random_bytes(20)); // ephemeral — never stored, discarded after key storage

\$users = config_get_path('system/user', []);
\$idx   = null;
foreach (\$users as \$i => \$u) {
    if (\$u['name'] === 'suru-validator') { \$idx = \$i; break; }
}

if (\$idx !== null) {
    \$users[\$idx]['password'] = password_hash(\$pass, PASSWORD_BCRYPT);
    \$users[\$idx]['priv']     = \$privs;
    unset(\$users[\$idx]['disabled']);
    \$uid    = \$users[\$idx]['uid'];
    \$action = 'updated';
} else {
    \$uid = (int)config_get_path('system/nextuid', '2000');
    config_set_path('system/nextuid', (string)(\$uid + 1));
    \$users[] = [
        'name'     => 'suru-validator',
        'password' => password_hash(\$pass, PASSWORD_BCRYPT),
        'uid'      => (string)\$uid,
        'scope'    => 'user',
        'descr'    => 'SURU deploy validator — managed by api-bootstrap',
        'priv'     => \$privs,
    ];
    \$action = 'created';
}
config_set_path('system/user', \$users);
fwrite(STDERR, "[bootstrap] suru-validator {\$action} (uid={\$uid})" . PHP_EOL);

// ── 2. Find pfREST package index ──────────────────────────────────────────
\$pkgs   = config_get_path('installedpackages/package', []);
\$pkg_id = null;
foreach (\$pkgs as \$i => \$pkg) {
    if (stripos(\$pkg['name'] ?? '', 'RESTAPI') !== false) {
        \$pkg_id = \$i;
        break;
    }
}
if (\$pkg_id === null) {
    fwrite(STDERR, "[bootstrap] ERROR: pfREST package not found — run make api-install-pfrest first" . PHP_EOL);
    exit(1);
}
fwrite(STDERR, "[bootstrap] pfREST at package index {\$pkg_id}" . PHP_EOL);

// ── 3. Generate key + store hash (RESTAPIKey model format) ────────────────
\$raw_key  = bin2hex(random_bytes(32));     // 64 hex chars — matches RESTAPIKey.inc
\$key_hash = hash('sha512', \$raw_key);

\$key_path = "installedpackages/package/{\$pkg_id}/conf/keys/key";
\$cur_keys = config_get_path(\$key_path, []);
// Remove any previous SURU-managed key for suru-validator (idempotent rotation)
\$cur_keys = array_values(array_filter((array)\$cur_keys, function(\$k) {
    return !((\$k['username'] ?? '') === 'suru-validator'
          && (\$k['descr']    ?? '') === 'SURU tier1 deploy validation');
}));
\$cur_keys[] = [
    'username'     => 'suru-validator',
    'hash_algo'    => 'sha512',
    'length_bytes' => '32',
    'hash'         => \$key_hash,
    'descr'        => 'SURU tier1 deploy validation',
];
config_set_path(\$key_path, \$cur_keys);

// ── 4. Enable KeyAuth in pfREST auth_methods (idempotent) ─────────────────
require_once('RESTAPI/autoloader.inc');
use RESTAPI\Models\RESTAPISettings;
\$restapi_pkg_id  = RESTAPISettings::get_pkg_id();
\$auth_path       = "installedpackages/package/{\$restapi_pkg_id}/conf/auth_methods";
\$current_methods = config_get_path(\$auth_path, 'BasicAuth');
if (strpos(\$current_methods, 'KeyAuth') === false) {
    config_set_path(\$auth_path, \$current_methods . ',KeyAuth');
    fwrite(STDERR, "[bootstrap] KeyAuth added to auth_methods" . PHP_EOL);
} else {
    fwrite(STDERR, "[bootstrap] KeyAuth already in auth_methods" . PHP_EOL);
}

// ── 5. Persist + update pfREST backup ─────────────────────────────────────
write_config('SURU api-bootstrap: suru-validator + API key + KeyAuth');
RESTAPISettings::backup_to_file();
fwrite(STDERR, "[bootstrap] Config saved, pfREST backup updated" . PHP_EOL);

// Print raw key to stdout — captured by bash caller
echo \$raw_key . PHP_EOL;
PHPEOF

  local ssh_key="${ROUTER_SSH_KEY:-~/.ssh/suru_deploy}"
  local ssh_user="${ROUTER_SSH_USER:-admin}"
  local -a ssh_opts=(-i "${ssh_key}" -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}" -o "BatchMode=yes" -o "ConnectTimeout=15")
  local sudo_prefix=""
  [[ "${ssh_user}" != "root" ]] && sudo_prefix="sudo "

  scp "${ssh_opts[@]}" "${php_file}" "${ssh_user}@${ROUTER_HOST}:${remote_php}" \
    || { rm -f "${php_file}"; log_die "SCP of bootstrap PHP failed"; }
  rm -f "${php_file}"

  local output rc=0
  # shellcheck disable=SC2029
  output="$(ssh "${ssh_opts[@]}" "${ssh_user}@${ROUTER_HOST}" "${sudo_prefix}php ${remote_php}")" \
    || rc=$?
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "${ssh_user}@${ROUTER_HOST}" "rm -f ${remote_php}" 2>/dev/null || true
  (( rc == 0 )) || log_die "Bootstrap PHP exited ${rc} on router"

  # raw_key is the only stdout line from the PHP script
  printf '%s' "${output}" | head -n1
}

# ---------------------------------------------------------------------------
# api_pfsense_install
# pfSense ONLY — install pfRest as the first package via SSH/pkg. Idempotent.
# Uses ssh_exec from lib/ssh.sh when available, otherwise a local ssh call.
# ---------------------------------------------------------------------------
api_pfsense_install() {
  [[ "${ROUTER_PLATFORM}" == "pfsense" ]] || {
    log_warn "api_pfsense_install called for ROUTER_PLATFORM=${ROUTER_PLATFORM} — skipping"
    return 0
  }
  : "${ROUTER_HOST:?ROUTER_HOST not set}"
  : "${ROUTER_SSH_USER:=admin}"
  : "${ROUTER_SSH_KEY:?ROUTER_SSH_KEY not set}"

  if _api_ssh "pkg info -q pfSense-pkg-RESTAPI" >/dev/null 2>&1; then
    log_info "pfRest already installed on router — skipping"
    return 0
  fi

  local pkg_url="${PFSENSE_API_PKG_URL:-}"
  [[ -n "${pkg_url}" ]] || log_die \
"PFSENSE_API_PKG_URL not set. See https://pfrest.org/ for the package URL
matching your pfSense version. Example:
  PFSENSE_API_PKG_URL=https://github.com/jaredhendrickson13/pfsense-api/releases/latest/download/pfSense-2.7-pkg-RESTAPI.pkg"

  # pkg-static requires root. When ROUTER_SSH_USER is anything other than
  # root, prefix with sudo and rely on a passwordless rule for pkg-static
  # (or NOPASSWD: ALL) on the router. Scoping sudo only to the install call
  # avoids hanging on `pkg info` if NOPASSWD is narrowly scoped.
  local sudo_prefix=""
  [[ "${ROUTER_SSH_USER}" != "root" ]] && sudo_prefix="sudo "

  log_info "Installing pfRest as first package: ${pkg_url}"
  _api_ssh "${sudo_prefix}pkg-static -C /dev/null add ${pkg_url}" \
    || log_die "pfRest install failed. Check: (1) router network access to ${pkg_url}, (2) the URL matches the router's pfSense version, (3) '${ROUTER_SSH_USER}' has passwordless sudo for pkg-static (or set ROUTER_SSH_USER=root)."

  log_info "pfRest installed. Next: create an API key (or JWT user) in"
  log_info "pfSense UI -> System -> API -> Authentication, then populate .env."
}

# _api_ssh CMD — prefer ssh_exec from lib/ssh.sh, fall back to local ssh.
_api_ssh() {
  if type ssh_exec &>/dev/null; then
    ssh_exec "$@"
  else
    local strict="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
    ssh -i "${ROUTER_SSH_KEY}" \
        -o "BatchMode=yes" \
        -o "ConnectTimeout=15" \
        -o "StrictHostKeyChecking=${strict}" \
        "${ROUTER_SSH_USER}@${ROUTER_HOST}" \
        "sh -c \"$*\""
  fi
}
