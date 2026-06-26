#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 3 Core  ·  apply-threat-intel.sh
# =============================================================================
# Purpose : Push STIX2 threat-intel bundles (rendered by tier2-telemetry's
#           future build/lib/render-stix2.sh from threat-intel/sources.yml,
#           T3 — not yet built) into OpenSearch Security Analytics' native
#           threat-intel-source ingestion (STIX2 via URL or file upload).
# Runtime : bash (per bash strict-mode (set -euo pipefail) — set -euo pipefail).
#           Differs deliberately from the sibling POSIX-sh init scripts
#           (apply-index-templates.sh, apply-ism-policies.sh) because this
#           task's spec explicitly calls for the bash-standards strict-mode
#           header; align with those scripts' Alpine/curlimages/curl runtime
#           model only if bash is later confirmed unavailable in that image.
# Container: intended for suru.t3.datalake.ti-init (one-shot init container,
#            wiring deferred to T7 — see header note below).
# Wired in by: T7's provisioner (tier3-core/scripts/deploy.sh, securityanalytics-
#            init + ti-init groups) — NOT wired into deploy.sh by this task.
#
# *** STATUS: STRUCTURE ONLY — BLOCKED ON T0a ***
# T0a (live verification of the OpenSearch Security Analytics plugin's actual
# REST endpoint shapes against the running 3.7.0 instance) has not run yet.
# The references skill (CONTRIBUTING.md) lists only the
# generic "OpenSearch API" docs home page — no Security Analytics-specific
# threat-intel-source endpoint is catalogued there.
#   [MISSING REFERENCE: OpenSearch Security Analytics threat-intel-source
#    REST API endpoint shapes (create-by-URL vs file-upload, response schema)
#    — propose web search: "OpenSearch Security Analytics threat intel source
#    API PUT _plugins/_security_analytics/threat_intel/sources"]
# The actual PUT/POST call below is therefore marked
# `# TODO: confirm exact endpoint per T0a` and MUST NOT be trusted to call a
# real endpoint until T0a completes and tier3-core/docs/security-analytics.md
# (T0a's deliverable) documents the verified shape. This script is safe to
# review/lint/dry-run today; it is not safe to wire into a live deploy yet.
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Log helpers ───────────────────────────────────────────────────────────────

_ts()       { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_info()  { printf '[%s] [INFO]  %s\n'  "$(_ts)" "$*"; }
log_warn()  { printf '[%s] [WARN]  %s\n'  "$(_ts)" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n'  "$(_ts)" "$*" >&2; }
log_die()   { log_error "$*"; exit 1; }

# ── Cleanup trap ──────────────────────────────────────────────────────────────

TMPFILES=()
_cleanup() {
  local ec=$?
  local f
  for f in "${TMPFILES[@]:-}"; do
    [[ -n "${f}" && -f "${f}" ]] && rm -f -- "${f}"
  done
  exit "${ec}"
}
trap _cleanup EXIT

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: apply-threat-intel.sh [--dry-run] [--verbose]

Pushes STIX2 threat-intel bundles into OpenSearch Security Analytics'
threat-intel-source ingestion. Idempotent: re-running re-applies the same
bundle set without creating duplicate sources (upsert-by-name, mirroring the
apply-index-templates.sh / apply-ism-policies.sh PUT convention).

Options:
  --dry-run   Print what would be applied; make no API calls.
  --verbose   Print extra diagnostic detail (bundle file list, endpoint URLs).
  -h, --help  Show this help.

Required env:
  OPENSEARCH_INITIAL_ADMIN_PASSWORD   OpenSearch admin password.

Optional env (defaults shown):
  OS_USER=admin
  OS_HOST=suru-t3-datalake-opensearch
  OS_PORT=9200
  STIX2_DIR=/config/threat-intel/stix2     # mounted bundle directory
  MAX_RETRIES=10
  RETRY_DELAY=15
EOF
}

# ── Flags ─────────────────────────────────────────────────────────────────────

DRY_RUN=false
VERBOSE=false

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=true ;;
      --verbose) VERBOSE=true ;;
      -h|--help) usage; exit 0 ;;
      *) log_die "Unknown argument: ${arg} (see --help)" ;;
    esac
  done

  : "${OPENSEARCH_INITIAL_ADMIN_PASSWORD:?OPENSEARCH_INITIAL_ADMIN_PASSWORD must be set}"
  local pass="${OPENSEARCH_INITIAL_ADMIN_PASSWORD}"

  local os_user="${OS_USER:-admin}"
  local os_host="${OS_HOST:-suru-t3-datalake-opensearch}"
  local os_port="${OS_PORT:-9200}"
  local stix2_dir="${STIX2_DIR:-/config/threat-intel/stix2}"
  local max_retries="${MAX_RETRIES:-10}"
  local retry_delay="${RETRY_DELAY:-15}"

  command -v curl   >/dev/null 2>&1 || log_die "curl is required but not found"
  command -v awk    >/dev/null 2>&1 || log_die "awk is required but not found"
  command -v mktemp >/dev/null 2>&1 || log_die "mktemp is required but not found"

  log_info "=== SURU threat-intel init starting ==="
  log_info "OpenSearch target : https://${os_host}:${os_port}"
  log_info "STIX2 bundle dir  : ${stix2_dir}"
  ${DRY_RUN} && log_info "Mode              : DRY-RUN (no API calls will be made)"

  wait_for_opensearch "${os_user}" "${pass}" "${os_host}" "${os_port}" "${max_retries}" "${retry_delay}"

  if [[ ! -d "${stix2_dir}" ]]; then
    log_warn "STIX2 bundle directory not found: ${stix2_dir} — nothing to apply"
    return 0
  fi

  local found=0 bundle
  for bundle in "${stix2_dir}"/*.json; do
    [[ -f "${bundle}" ]] || continue
    found=$(( found + 1 ))
    apply_stix2_bundle "${bundle}" "${os_user}" "${pass}" "${os_host}" "${os_port}"
  done

  if [[ "${found}" -eq 0 ]]; then
    log_warn "No STIX2 bundle files found in '${stix2_dir}' — has tier2-telemetry's render-stix2.sh (T3) run yet?"
  else
    log_info "=== Processed ${found} STIX2 bundle(s) — init complete ==="
  fi
}

# ── wait_for_opensearch ───────────────────────────────────────────────────────

wait_for_opensearch() {
  local os_user="$1" pass="$2" os_host="$3" os_port="$4" max_retries="$5" retry_delay="$6"
  local attempt=0 status

  while [[ "${attempt}" -lt "${max_retries}" ]]; do
    attempt=$(( attempt + 1 ))
    log_info "Waiting for OpenSearch (attempt ${attempt}/${max_retries}) ..."

    status="$(curl -sk -u "${os_user}:${pass}" \
      "https://${os_host}:${os_port}/_cluster/health?pretty" \
      --connect-timeout 5 --max-time 10 \
      | awk -F'"' '/"status"/{print $4; exit}' || true)"

    case "${status}" in
      green|yellow)
        log_info "OpenSearch is ready (status: ${status})"
        return 0
        ;;
      *)
        log_warn "OpenSearch not ready yet (status: '${status}'); retrying in ${retry_delay}s"
        sleep "${retry_delay}"
        ;;
    esac
  done

  log_die "OpenSearch did not become ready after ${max_retries} retries"
}

# ── apply_stix2_bundle ────────────────────────────────────────────────────────
# Pushes one STIX2 bundle file into OpenSearch Security Analytics'
# threat-intel-source ingestion. The bundle's filename (minus extension) is
# used as the threat-intel-source name — this gives upsert-by-name idempotency
# once the real endpoint supports it (per T0a verification).
# ---------------------------------------------------------------------------

apply_stix2_bundle() {
  local bundle_file="$1" os_user="$2" pass="$3" os_host="$4" os_port="$5"
  local source_name
  source_name="$(basename -- "${bundle_file}")"
  source_name="${source_name%.json}"

  log_info "Bundle: ${bundle_file} -> threat-intel-source '${source_name}'"
  ${VERBOSE} && log_info "  (verbose) full path: ${bundle_file}"

  if ${DRY_RUN}; then
    log_info "  [dry-run] would PUT STIX2 bundle as threat-intel-source '${source_name}'"
    return 0
  fi

  # TODO: confirm exact endpoint per T0a.
  #
  # OpenSearch Security Analytics' Custom Threat Intel Source feature is
  # documented (product-level) to accept STIX2 bundles via either a remote
  # URL or a direct file/IOC upload, but the EXACT REST path, HTTP verb, and
  # request-body schema for the running 3.7.0 instance have not been
  # confirmed live (T0a, deferred to Executor stage per the plan, still
  # pending as of this task). Do not uncomment/trust the call below until
  # T0a's findings are written to tier3-core/docs/security-analytics.md and
  # this comment is replaced with a citation to that doc.
  #
  # local endpoint="/_plugins/_security_analytics/threat_intel/sources"
  # local tmpfile
  # tmpfile="$(mktemp)" || log_die "mktemp failed"
  # TMPFILES+=("${tmpfile}")
  # printf '%s\n' "$(cat -- "${bundle_file}")" > "${tmpfile}"
  #
  # local http_code
  # http_code="$(curl -sk -o /dev/null -w '%{http_code}' \
  #   -X POST -u "${os_user}:${pass}" \
  #   -H 'Content-Type: application/json' \
  #   --data-binary "@${tmpfile}" \
  #   "https://${os_host}:${os_port}${endpoint}")" || true
  #
  # case "${http_code}" in
  #   200|201) log_info "OK — threat-intel-source applied (HTTP ${http_code}): ${source_name}" ;;
  #   401)     log_die "Unauthorized (HTTP 401) applying threat-intel-source: ${source_name}" ;;
  #   5*)      log_die "Server error (HTTP ${http_code}) applying threat-intel-source: ${source_name}" ;;
  #   *)       log_warn "Unexpected response (HTTP ${http_code}) applying threat-intel-source: ${source_name}" ;;
  # esac

  log_warn "BLOCKED on T0a — threat-intel-source API call for '${source_name}' is not yet enabled (structure-only). See header comment and [MISSING REFERENCE] note."
}

main "$@"
