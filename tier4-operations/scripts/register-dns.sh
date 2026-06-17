#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 4 Operations / register-dns.sh
# =============================================================================
# Registers (or removes) a DNS host override on the perimeter router so LAN
# clients without mDNS — chiefly Windows — can resolve FRONTDOOR_FQDN to
# FRONTDOOR_IP. Talks to:
#
#   - pfSense  via the pfREST community package (jaredhendrickson13/pfsense-api).
#                Endpoints: /services/dns_resolver/host_override(s) + /apply
#   - OPNsense via the stock Unbound REST API.
#                Endpoints: /unbound/settings/{add,set,del,search}HostOverride +
#                           /unbound/service/reconfigure
#
# Inputs:
#   - tier4-operations/.env: FRONTDOOR_FQDN, FRONTDOOR_IP
#   - tier1-perimeter/.env:  ROUTER_PLATFORM, ROUTER_HOST, API credentials
#                            (PFSENSE_API_KEY etc. — see tier1's lib/api.sh)
#
# Usage:
#   register-dns.sh register   [--dry-run] [--verbose]
#   register-dns.sh unregister [--dry-run] [--verbose]
#   register-dns.sh show       [--verbose]              # list current host override(s) for FQDN
#
# FRONTDOOR_FQDN          Primary user-access URL (single value).
# FRONTDOOR_INGESTION_FQDNS
#                         Comma-separated ingestion SNI hostnames
#                         (e.g. syslog.suru.local,beats.suru.local).
#                         All entries are registered to the same FRONTDOOR_IP.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER4_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${TIER4_DIR}/.." && pwd)"

TIER4_ENV="${TIER4_DIR}/.env"
TIER1_ENV="${REPO_ROOT}/tier1-perimeter/.env"

API_LIB="${REPO_ROOT}/tier1-perimeter/scripts/lib/api.sh"
LOG_LIB="${REPO_ROOT}/tier1-perimeter/scripts/lib/log.sh"

# ── CLI ────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
ACTION=""

usage() {
  cat <<'EOF'
Usage: register-dns.sh <action> [--dry-run] [--verbose]

Actions:
  register     Create or update the FQDN host override on the router.
  unregister   Remove the host override.
  show         Print the current host override (if any) for FQDN.

Options:
  --dry-run    Print what would happen; do not call the router API.
  --verbose    Echo API requests + responses.
  -h, --help   Show this help.
EOF
}

[[ $# -eq 0 ]] && { usage; exit 0; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac
ACTION="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$ACTION" in
  register|unregister|show) : ;;
  *) echo "Unknown action: $ACTION" >&2; usage >&2; exit 2 ;;
esac

# ── Load env ──────────────────────────────────────────────────────────────────────────
load_env_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    set -a; # shellcheck disable=SC1090
    source "$f"; set +a
    $VERBOSE && echo "[INFO] Loaded $f"
  else
    echo "[WARN] $f not found — relying on shell environment" >&2
  fi
}
load_env_file "$TIER1_ENV"
load_env_file "$TIER4_ENV"

# ── Source tier1 helpers ────────────────────────────────────────────────────────────────
[[ -f "$LOG_LIB" ]] || { echo "[ERROR] $LOG_LIB missing" >&2; exit 1; }
[[ -f "$API_LIB" ]] || { echo "[ERROR] $API_LIB missing" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LOG_LIB"
# shellcheck disable=SC1090
source "$API_LIB"

# ── Validate inputs ───────────────────────────────────────────────────────────────────
: "${FRONTDOOR_FQDN:=suru.local}"
: "${FRONTDOOR_IP:=}"
: "${FRONTDOOR_INGESTION_FQDNS:=}"

if [[ "$ACTION" == "register" || "$ACTION" == "show" ]]; then
  if [[ -z "$FRONTDOOR_IP" || "$FRONTDOOR_IP" == "127.0.0.1" ]]; then
    log_warn "FRONTDOOR_IP is '${FRONTDOOR_IP:-unset}' — registering a loopback on the router is rarely useful."
    log_warn "Set FRONTDOOR_IP to the Docker host's LAN-routable IPv4 in tier4-operations/.env."
    if [[ "$ACTION" == "register" ]]; then
      $DRY_RUN || { log_err "Refusing to register a loopback as router DNS target."; exit 1; }
    fi
  fi
fi

# _parse_fqdn FQDN — sets HOST_PART, DOMAIN_PART, DESCR for use by platform functions.
_parse_fqdn() {
  local fqdn="$1"
  HOST_PART="${fqdn%%.*}"
  DOMAIN_PART="${fqdn#*.}"
  if [[ "$DOMAIN_PART" == "$fqdn" || -z "$DOMAIN_PART" ]]; then
    log_err "FQDN '${fqdn}' must contain a domain part (e.g. suru.local)"
    exit 1
  fi
  DESCR="SURU frontdoor ingestion endpoint — ${fqdn} (managed by tier4-operations/scripts/register-dns.sh)"
}

# ── Init tier1 API client ───────────────────────────────────────────────────────────────
api_init

if $DRY_RUN; then
  log_info "[DRY-RUN] action=${ACTION} platform=${ROUTER_PLATFORM} host=${ROUTER_HOST}"
  log_info "[DRY-RUN] FRONTDOOR_FQDN=${FRONTDOOR_FQDN:-<unset>}  FRONTDOOR_IP=${FRONTDOOR_IP:-<unset>}"
  log_info "[DRY-RUN] FRONTDOOR_INGESTION_FQDNS=${FRONTDOOR_INGESTION_FQDNS:-<unset>}"
  log_info "[DRY-RUN] (would POST/PATCH/DELETE host overrides on the router for all listed FQDNs)"
  exit 0
fi

# =============================================================================
# pfSense (pfREST v2)
#
# IMPORTANT: The pfREST v2 OpenAPI spec at /schema/openapi incorrectly documents
# DELETE id as "in=query". In practice pfREST v2 reads `id` from the JSON body
# for DELETE (same pattern as PATCH). Sending ?id=N returns MODEL_REQUIRES_ID.
# See tier4-operations/docs/pfsense-api-v2.md for full reference.
#
# Singular endpoint (/host_override) — single-item CRUD:
#   GET    ?id=N                          read one
#   POST   body: {host,domain,ip,descr}   create
#   PATCH  body: {id,host,domain,...}     update (apply:true triggers reload)
#   DELETE body: {id,apply}              delete + immediate reload
#
# Plural endpoint (/host_overrides) — collection:
#   GET    ?limit&offset&query            list
# =============================================================================
pfsense_find_id() {
  local resp
  resp="$(api_request GET /services/dns_resolver/host_overrides 2>/dev/null || true)"
  [[ -z "$resp" ]] && return 0
  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq -r --arg h "$HOST_PART" --arg d "$DOMAIN_PART" \
      '.data // . | map(select(.host == $h and .domain == $d)) | .[0].id // empty'
  else
    echo "$resp" | grep -oE '"id":[[:space:]]*[0-9]+,[^}]*"host":[[:space:]]*"'"${HOST_PART}"'"[^}]*"domain":[[:space:]]*"'"${DOMAIN_PART}"'"' \
      | head -1 | sed -n 's/.*"id":[[:space:]]*\([0-9]*\).*/\1/p'
  fi
}

# pfsense_apply — REST apply + exec-based Unbound service restart.
#
# Called after POST (create), since POST has no built-in apply parameter.
# PATCH and DELETE pass apply:true in the body and handle their own reload.
pfsense_apply() {
  log_info "pfSense: applying DNS resolver config (REST)"
  api_request POST /services/dns_resolver/apply >/dev/null 2>&1 || true

  log_info "pfSense: reloading Unbound service via exec"
  _api_pfsense_exec "service unbound restart" >/dev/null \
    && log_info "pfSense: Unbound reloaded." \
    || log_warn "pfSense: Unbound reload via exec failed (rc=${_API_EXEC_RC})" \
                "DNS entry is saved but may require manual Apply in the pfSense GUI."
}

pfsense_register() {
  local existing_id body resp
  existing_id="$(pfsense_find_id)"
  body=$(printf '{"host":"%s","domain":"%s","ip":["%s"],"descr":"%s"}' \
           "$HOST_PART" "$DOMAIN_PART" "$FRONTDOOR_IP" "$DESCR")
  if [[ -n "$existing_id" ]]; then
    log_info "pfSense: updating host override id=${existing_id}"
    body=$(printf '{"id":%s,"host":"%s","domain":"%s","ip":["%s"],"descr":"%s","apply":true}' \
             "$existing_id" "$HOST_PART" "$DOMAIN_PART" "$FRONTDOOR_IP" "$DESCR")
    resp="$(api_request PATCH /services/dns_resolver/host_override "$body")"
  else
    log_info "pfSense: creating host override ${HOST_PART}.${DOMAIN_PART} -> ${FRONTDOOR_IP}"
    resp="$(api_request POST /services/dns_resolver/host_override "$body")"
  fi
  $VERBOSE && echo "$resp"
  pfsense_apply
  log_info "pfSense: done."
}

pfsense_unregister() {
  local existing_id
  existing_id="$(pfsense_find_id)"
  if [[ -z "$existing_id" ]]; then
    log_info "pfSense: no host override for ${HOST_PART}.${DOMAIN_PART} — nothing to remove."
    return 0
  fi
  log_info "pfSense: deleting host override id=${existing_id}"
  # pfREST v2 DELETE: id goes in the JSON body (not ?id= query param).
  # apply:true triggers immediate Unbound reload via pfREST internally.
  api_request DELETE "/services/dns_resolver/host_override" \
    "$(printf '{"id":%s,"apply":true}' "${existing_id}")" >/dev/null
  log_info "pfSense: done."
}

pfsense_show() {
  local existing_id resp
  existing_id="$(pfsense_find_id)"
  if [[ -z "$existing_id" ]]; then
    log_info "pfSense: no host override for ${HOST_PART}.${DOMAIN_PART}"
    return 0
  fi
  resp="$(api_request GET /services/dns_resolver/host_overrides)"
  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq --argjson id "$existing_id" '.data // . | map(select(.id == $id)) | .[0]'
  else
    echo "$resp"
  fi
}

# =============================================================================
# OPNsense (stock Unbound REST API)
# =============================================================================
opnsense_find_uuid() {
  local resp
  resp="$(api_request POST /unbound/settings/searchHostOverride '{}' 2>/dev/null || true)"
  [[ -z "$resp" ]] && return 0
  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq -r --arg h "$HOST_PART" --arg d "$DOMAIN_PART" \
      '.rows // [] | map(select(.hostname == $h and .domain == $d)) | .[0].uuid // empty'
  else
    log_warn "jq not available — UUID lookup may be inaccurate"
    echo "$resp" | sed -n 's/.*"uuid":"\([^"]*\)".*"hostname":"'"${HOST_PART}"'".*"domain":"'"${DOMAIN_PART}"'".*/\1/p' | head -1
  fi
}

opnsense_register() {
  local existing_uuid body resp
  existing_uuid="$(opnsense_find_uuid)"
  body=$(printf '{"host":{"enabled":"1","hostname":"%s","domain":"%s","rr":"A","server":"%s","description":"%s"}}' \
           "$HOST_PART" "$DOMAIN_PART" "$FRONTDOOR_IP" "$DESCR")
  if [[ -n "$existing_uuid" ]]; then
    log_info "OPNsense: updating host override uuid=${existing_uuid}"
    resp="$(api_request POST "/unbound/settings/setHostOverride/${existing_uuid}" "$body")"
  else
    log_info "OPNsense: creating host override ${HOST_PART}.${DOMAIN_PART} -> ${FRONTDOOR_IP}"
    resp="$(api_request POST /unbound/settings/addHostOverride "$body")"
  fi
  $VERBOSE && echo "$resp"
  log_info "OPNsense: reconfiguring unbound"
  api_request POST /unbound/service/reconfigure '{}' >/dev/null
  log_info "OPNsense: done."
}

opnsense_unregister() {
  local existing_uuid
  existing_uuid="$(opnsense_find_uuid)"
  if [[ -z "$existing_uuid" ]]; then
    log_info "OPNsense: no host override for ${HOST_PART}.${DOMAIN_PART} — nothing to remove."
    return 0
  fi
  log_info "OPNsense: deleting host override uuid=${existing_uuid}"
  api_request POST "/unbound/settings/delHostOverride/${existing_uuid}" '{}' >/dev/null
  api_request POST /unbound/service/reconfigure '{}' >/dev/null
  log_info "OPNsense: done."
}

opnsense_show() {
  local resp
  resp="$(api_request POST /unbound/settings/searchHostOverride '{}')"
  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq --arg h "$HOST_PART" --arg d "$DOMAIN_PART" \
      '.rows // [] | map(select(.hostname == $h and .domain == $d)) | .[0] // "no matching override"'
  else
    echo "$resp"
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────────────
# Build the full list of FQDNs to process: FRONTDOOR_FQDN + FRONTDOOR_INGESTION_FQDNS.
# FRONTDOOR_FQDN is the main user-access URL; FRONTDOOR_INGESTION_FQDNS is a
# comma-separated list of ingestion SNI hostnames. Both resolve to FRONTDOOR_IP.
_all_fqdns=()
[[ -n "${FRONTDOOR_FQDN:-}" ]] && _all_fqdns+=("$FRONTDOOR_FQDN")
if [[ -n "${FRONTDOOR_INGESTION_FQDNS:-}" ]]; then
  IFS=',' read -ra _ing_fqdns <<< "$FRONTDOOR_INGESTION_FQDNS"
  for _f in "${_ing_fqdns[@]}"; do
    _f="${_f# }"; _f="${_f% }"   # trim whitespace
    [[ -n "$_f" ]] && _all_fqdns+=("$_f")
  done
fi

if [[ ${#_all_fqdns[@]} -eq 0 ]]; then
  log_err "No FQDNs to register — set FRONTDOOR_FQDN and/or FRONTDOOR_INGESTION_FQDNS"
  exit 1
fi

case "$ROUTER_PLATFORM" in
  pfsense)
    for _fqdn in "${_all_fqdns[@]}"; do
      log_info "pfSense: processing FQDN: ${_fqdn}"
      _parse_fqdn "$_fqdn"
      case "$ACTION" in
        register)   pfsense_register ;;
        unregister) pfsense_unregister ;;
        show)       pfsense_show ;;
      esac
    done
    ;;
  opnsense)
    for _fqdn in "${_all_fqdns[@]}"; do
      log_info "OPNsense: processing FQDN: ${_fqdn}"
      _parse_fqdn "$_fqdn"
      case "$ACTION" in
        register)   opnsense_register ;;
        unregister) opnsense_unregister ;;
        show)       opnsense_show ;;
      esac
    done
    ;;
  *)
    log_err "Unsupported ROUTER_PLATFORM=${ROUTER_PLATFORM}"
    exit 1
    ;;
esac
