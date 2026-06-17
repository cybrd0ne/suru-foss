#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 4 / check-env-consistency.sh
# Post-deployment cross-tier .env consistency and DNS validation.
#
# Checks:
#   1. FRONTDOOR alignment       — tier1 SNI in tier4 FRONTDOOR_INGESTION_FQDNS;
#                                  FRONTDOOR_PORT matches; FRONTDOOR_IP is LAN-routable
#   2. OpenSearch credentials    — no CHANGE_ME placeholders; logstash user correct
#   3. Removed-variable guard    — SIEM_HOST / SIEM_SYSLOG_PORT absent from tier1 .env
#   4. DNS resolution on router  — tier1 SNI resolves to FRONTDOOR_IP (pfSense only)
#
# Usage:
#   check-env-consistency.sh [--verbose] [--dry-run] [-h|--help]
#
# Exit code: 0 = all PASS (WARNs OK); 1 = any FAIL.
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER4_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${TIER4_DIR}/.." && pwd)"

TIER1_ENV="${REPO_ROOT}/tier1-perimeter/.env"
TIER3_ENV="${REPO_ROOT}/tier3-core/.env"
TIER4_ENV="${TIER4_DIR}/.env"
API_LIB="${REPO_ROOT}/tier1-perimeter/scripts/lib/api.sh"
LOG_LIB="${REPO_ROOT}/tier1-perimeter/scripts/lib/log.sh"

DRY_RUN=false
VERBOSE=false
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0

usage() { cat <<'EOF'
Usage: check-env-consistency.sh [--verbose] [--dry-run] [-h|--help]

Validates cross-tier .env consistency (tier1 / tier3 / tier4) and
verifies the tier1 syslog SNI hostname resolves to the frontdoor IP
on the perimeter router.

Exit code: 0 if all checks pass; 1 if any check fails.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --verbose)  VERBOSE=true ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ── Local reporter ────────────────────────────────────────────────────────────
check_pass() { echo "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
check_fail() { echo "[FAIL] $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check_warn() { echo "[WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }

# ── Load .env files ───────────────────────────────────────────────────────────
load_env_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f" || true   # tolerate non-zero exit from .env (e.g. comments, subshells)
    set +a
    if $VERBOSE; then echo "[INFO] Loaded $f"; fi
  else
    check_warn ".env not found: $f — checks may be incomplete"
  fi
}
load_env_file "$TIER1_ENV"
load_env_file "$TIER3_ENV"
load_env_file "$TIER4_ENV"

# Source tier1 libs (log.sh then api.sh); tolerate absence for offline use.
if [[ -f "$LOG_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$LOG_LIB"
fi
if [[ -f "$API_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$API_LIB"
fi

# ── Check 1: FRONTDOOR alignment ─────────────────────────────────────────────
check_frontdoor_alignment() {
  local sni="${FRONTDOOR_SYSLOG_SNI:-}"
  local t1_port="${FRONTDOOR_PORT:-}"
  local fqdns="${FRONTDOOR_INGESTION_FQDNS:-}"
  local t4_port="443"   # tier4 default; override if tier4 sets FRONTDOOR_PORT
  # tier4 .env FRONTDOOR_PORT may also be set; after loading both envs the last
  # write wins — use the value as-is (both should be 443).
  local ip="${FRONTDOOR_IP:-}"

  # SNI set
  if [[ -z "$sni" ]]; then
    check_fail "FRONTDOOR_SYSLOG_SNI not set in tier1 .env"
  else
    check_pass "FRONTDOOR_SYSLOG_SNI is set: $sni"
  fi

  # SNI in FRONTDOOR_INGESTION_FQDNS
  if [[ -n "$sni" && -n "$fqdns" ]]; then
    local found=false
    while IFS= read -r entry; do
      entry="${entry## }"; entry="${entry%% }"
      [[ "$entry" == "$sni" ]] && found=true && break
    done < <(printf '%s\n' "$fqdns" | tr ',' '\n')
    if $found; then
      check_pass "FRONTDOOR_SYSLOG_SNI '$sni' is in FRONTDOOR_INGESTION_FQDNS"
    else
      check_fail "FRONTDOOR_SYSLOG_SNI '$sni' not found in FRONTDOOR_INGESTION_FQDNS='$fqdns'"
    fi
  elif [[ -n "$sni" ]]; then
    check_warn "FRONTDOOR_INGESTION_FQDNS not set — cannot verify SNI membership"
  fi

  # FRONTDOOR_PORT matches
  if [[ -n "$t1_port" && "$t1_port" != "$t4_port" ]]; then
    check_fail "FRONTDOOR_PORT mismatch: tier1=$t1_port vs expected=$t4_port"
  elif [[ -z "$t1_port" ]]; then
    check_warn "FRONTDOOR_PORT not set in tier1 .env"
  else
    check_pass "FRONTDOOR_PORT=$t1_port"
  fi

  # FRONTDOOR_IP is a LAN-routable address
  if [[ -z "$ip" ]]; then
    check_fail "FRONTDOOR_IP not set in tier4 .env"
  elif [[ "$ip" == "127."* || "$ip" == "::1" || "$ip" == "0.0.0.0" ]]; then
    check_fail "FRONTDOOR_IP='$ip' is loopback/unspecified — set it to the LAN IPv4 in tier4 .env"
  else
    check_pass "FRONTDOOR_IP=$ip"
  fi
}

# ── Check 2: OpenSearch credentials ──────────────────────────────────────────
check_opensearch_creds() {
  local admin_pw="${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}"
  local ls_user="${LOGSTASH_OPENSEARCH_USER:-}"
  local dash_user="${OPENSEARCH_DASHBOARDS_USER:-}"

  if [[ -z "$admin_pw" ]]; then
    check_warn "OPENSEARCH_INITIAL_ADMIN_PASSWORD not set"
  elif [[ "$admin_pw" == CHANGE_ME* ]]; then
    check_fail "OPENSEARCH_INITIAL_ADMIN_PASSWORD is a placeholder (CHANGE_ME*) — set a real password"
  else
    check_pass "OPENSEARCH_INITIAL_ADMIN_PASSWORD is set and non-placeholder"
  fi

  if [[ -z "$ls_user" ]]; then
    check_warn "LOGSTASH_OPENSEARCH_USER not set"
  elif [[ "$ls_user" != "logstash" ]]; then
    check_fail "LOGSTASH_OPENSEARCH_USER='$ls_user' — must be 'logstash' (not 'admin'; see PR #78)"
  else
    check_pass "LOGSTASH_OPENSEARCH_USER=logstash"
  fi

  if [[ -z "$dash_user" ]]; then
    check_fail "OPENSEARCH_DASHBOARDS_USER not set"
  else
    check_pass "OPENSEARCH_DASHBOARDS_USER=$dash_user"
  fi
}

# ── Check 3: Removed-variable guard ──────────────────────────────────────────
check_removed_vars() {
  # These were removed in PR #82; their presence in tier1 .env means the
  # operator hasn't updated the env and syslog-ng will connect to the old
  # direct Logstash address instead of the frontdoor.
  local found_siem_host=false found_siem_port=false

  if [[ -f "$TIER1_ENV" ]]; then
    grep -q '^[[:space:]]*SIEM_HOST[[:space:]]*=' "$TIER1_ENV" 2>/dev/null && found_siem_host=true
    grep -q '^[[:space:]]*SIEM_SYSLOG_PORT[[:space:]]*=' "$TIER1_ENV" 2>/dev/null && found_siem_port=true
  fi

  if $found_siem_host; then
    check_fail "SIEM_HOST still present in tier1 .env — replace with FRONTDOOR_SYSLOG_SNI (PR #82)"
  else
    check_pass "SIEM_HOST absent from tier1 .env (correctly removed)"
  fi

  if $found_siem_port; then
    check_fail "SIEM_SYSLOG_PORT still present in tier1 .env — replace with FRONTDOOR_PORT (PR #82)"
  else
    check_pass "SIEM_SYSLOG_PORT absent from tier1 .env (correctly removed)"
  fi
}

# ── Check 4: DNS resolution on router ────────────────────────────────────────
check_dns_resolution() {
  local sni="${FRONTDOOR_SYSLOG_SNI:-}"
  local expected_ip="${FRONTDOOR_IP:-}"
  local platform="${ROUTER_PLATFORM:-}"
  local router_host="${ROUTER_HOST:-}"

  if [[ -z "$sni" || -z "$expected_ip" ]]; then
    check_warn "DNS check skipped — FRONTDOOR_SYSLOG_SNI or FRONTDOOR_IP not set"
    return
  fi

  if [[ -z "$router_host" ]]; then
    check_warn "DNS check skipped — ROUTER_HOST not set (offline mode)"
    return
  fi

  # Validate SNI to prevent injection in the exec command
  if [[ ! "$sni" =~ ^[A-Za-z0-9.-]+$ ]]; then
    check_fail "FRONTDOOR_SYSLOG_SNI='$sni' contains invalid characters — cannot run DNS check"
    return
  fi

  if [[ "$platform" != "pfsense" ]]; then
    check_warn "DNS check not supported on platform='$platform' (pfSense only)"
    return
  fi

  # Require at least one auth credential
  local has_creds=false
  [[ -n "${PFSENSE_API_KEY:-}" ]] && has_creds=true
  [[ -n "${PFSENSE_API_USERNAME:-}" && -n "${PFSENSE_API_PASSWORD:-}" ]] && has_creds=true
  if ! $has_creds; then
    check_warn "DNS check skipped — no pfSense API credentials (PFSENSE_API_KEY or USERNAME/PASSWORD)"
    return
  fi

  if $DRY_RUN; then
    check_warn "DNS check skipped in --dry-run mode (would exec: getent hosts -- $sni on $router_host)"
    return
  fi

  api_init 2>/dev/null || { check_warn "DNS check skipped — api_init failed"; return; }

  local out
  # FreeBSD getent does not support -- so pass the name directly.
  # _api_pfsense_exec sets _API_EXEC_RC; non-zero means NXDOMAIN or error.
  out="$(_api_pfsense_exec "getent hosts ${sni}" 2>/dev/null)" || true

  if [[ -z "$out" || "${_API_EXEC_RC:-1}" -ne 0 ]]; then
    check_fail "DNS: '$sni' does not resolve on router $router_host (NXDOMAIN or error; rc=${_API_EXEC_RC:-?})"
    return
  fi

  # getent hosts output: "IP canonical aliases..."
  # Check if any line's first field matches FRONTDOOR_IP
  local resolved_ip match=false
  while IFS= read -r line; do
    resolved_ip="$(echo "$line" | awk '{print $1}')"
    [[ "$resolved_ip" == "$expected_ip" ]] && match=true && break
  done <<< "$out"

  if $match; then
    check_pass "DNS: '$sni' resolves to $expected_ip on router (FRONTDOOR_IP matches)"
  else
    resolved_ip="$(echo "$out" | awk 'NR==1{print $1}')"
    check_fail "DNS: '$sni' resolves to '$resolved_ip' on router — expected FRONTDOOR_IP='$expected_ip'"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "=== SURU Cross-Tier .env Consistency Check ==="
echo ""
echo "--- 1. Frontdoor alignment ---"
check_frontdoor_alignment
echo ""
echo "--- 2. OpenSearch credentials ---"
check_opensearch_creds
echo ""
echo "--- 3. Removed-variable guard (PR #82 regression) ---"
check_removed_vars
echo ""
echo "--- 4. DNS resolution on router ---"
check_dns_resolution
echo ""
echo "=== Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $WARN_COUNT warned ==="

[[ $FAIL_COUNT -eq 0 ]]
