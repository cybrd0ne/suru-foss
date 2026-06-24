#!/usr/bin/env bash
# SURU Platform — pfBlockerNG feed download/compile baseline check
#
# Cross-checks every SURU_-managed pfBlockerNG alias actually configured on
# the router against the live download/compile evidence in:
#   /var/db/pfblockerng/deny/      — compiled IPv4 deny-list output
#   /var/db/pfblockerng/dnsbl/     — compiled DNSBL output
#   /var/db/pfblockerng/dnsblorig/ — raw feed downloads, pre-compile
#
# A SURU_ alias with a config entry but NO file in the matching directory
# means pfBlockerNG never successfully downloaded/compiled it — the exact
# failure mode this script exists to catch (see dnsbl-categories.yml header
# for the incident this codifies: every SURU DNSBL alias had
# action="Deny Both" instead of "unbound" and zero files in dnsblorig/ as
# a result).
#
# Usage: ./verify-pfblockerng-feeds.sh [--dry-run] [--verbose]
# Requires: ROUTER_HOST, ROUTER_SSH_USER, ROUTER_SSH_KEY in .env (same as deploy.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

DRY_RUN=false
VERBOSE=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
  esac
done
export DRY_RUN VERBOSE

# .env is loaded by the Makefile (-include + export) before this script
# runs, same as deploy.sh — not re-sourced here.
: "${ROUTER_HOST:?Set ROUTER_HOST in .env}"
: "${ROUTER_SSH_USER:?Set ROUTER_SSH_USER in .env}"
: "${ROUTER_SSH_KEY:?Set ROUTER_SSH_KEY in .env}"

# Pull aliasname+action pairs straight out of the live config.xml via
# xmllint (always present on pfSense) + awk — avoids depending on xml2json,
# which is not guaranteed present on every pfSense build.
dnsbl_raw="$(ssh_exec '/usr/local/bin/xmllint --xpath "//pfblockerngdnsbl/config" /conf/config.xml' 2>/dev/null || true)"
ipv4_raw="$(ssh_exec '/usr/local/bin/xmllint --xpath "//pfblockernglistsv4/config" /conf/config.xml' 2>/dev/null || true)"

_extract_suru_aliases() {
  # $1 = raw xmllint output for one section. Prints "aliasname|action" lines
  # (pipe-delimited — action values like "Deny Both" contain spaces, so a
  # plain space-joined pair can't be split back apart unambiguously) for
  # every SURU_-prefixed <config> block.
  awk '
    /<aliasname>/ { gsub(/<\/?aliasname>/, ""); name=$0; gsub(/^[ \t]+|[ \t]+$/, "", name) }
    /<action>/    { gsub(/<\/?action>/, ""); action=$0; gsub(/^[ \t]+|[ \t]+$/, "", action)
                    if (name ~ /^SURU_/) print name "|" action
                    name=""; action="" }
  ' <<< "$1"
}

_extract_suru_ipv4_headers() {
  # $1 = raw xmllint output for //pfblockernglistsv4/config. pfBlockerNG
  # compiles deny/ output per individual <row><header>, not per parent
  # <aliasname> — SURU_IP_C2 never exists as a filename; SURU_FeodoTracker
  # (one of its rows) does. Prints "aliasname|header" for every <header>
  # nested under a SURU_-prefixed alias.
  awk '
    /<aliasname>/ { gsub(/<\/?aliasname>/, ""); alias=$0; gsub(/^[ \t]+|[ \t]+$/, "", alias) }
    /<header>/    { gsub(/<\/?header>/, ""); header=$0; gsub(/^[ \t]+|[ \t]+$/, "", header)
                    if (alias ~ /^SURU_/) print alias "|" header }
  ' <<< "$1"
}

log_info "Checking live pfBlockerNG config (config.xml) for SURU_ aliases..."
# Portable read loop (not mapfile/readarray) — macOS ships bash 3.2 by
# default and this script targets the operator's machine, not the router.
dnsbl_aliases=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && dnsbl_aliases+=("${line}")
done < <(_extract_suru_aliases "${dnsbl_raw}")
ipv4_headers=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && ipv4_headers+=("${line}")
done < <(_extract_suru_ipv4_headers "${ipv4_raw}")

if [[ "${#dnsbl_aliases[@]}" -eq 0 && "${#ipv4_headers[@]}" -eq 0 ]]; then
  log_die "No SURU_ aliases found in live config — run render.sh + make deploy first."
fi

log_info "Checking on-disk download/compile evidence..."
deny_files="$(ssh_exec 'ls -1 /var/db/pfblockerng/deny/ 2>/dev/null' || true)"
dnsblorig_files="$(ssh_exec 'ls -1 /var/db/pfblockerng/dnsblorig/ 2>/dev/null' || true)"

fail_count=0

# --- Live enforcement check ------------------------------------------------
# Download/compile success (the checks below) does NOT prove DNS-level
# enforcement is active — they are independent failure points.
# pfb_unbound_dnsbl() activates the DNSBL python module by
# prepending it to unbound.conf's module-config: "validator iterator" ->
# "python validator iterator". Module order is what makes the python module
# finalize a blocked query BEFORE the iterator module ever consults a
# forward-zone (Cloudflare DoT, any other upstream, or plain recursive
# resolution) — so checking that "python" precedes "iterator" here is
# sufficient to confirm DNSBL enforcement takes precedence over ANY
# forwarding configuration, without needing to know what that config is.
# This can regress silently: any unrelated unbound.conf regeneration (DNS
# Resolver GUI save, WAN IP change) rewrites module-config from pfSense's
# own template, which knows nothing about pfBlockerNG's python module, and
# the insertion is lost until sync_package_pfblockerng() runs again.
if [[ "${#dnsbl_aliases[@]}" -gt 0 ]]; then
  module_config="$(ssh_exec 'grep -m1 "module-config" /var/unbound/unbound.conf 2>/dev/null' || true)"
  echo
  echo "=== DNSBL live enforcement (unbound.conf module-config) ==="
  if [[ "${module_config}" =~ \"python[^\"]*iterator ]]; then
    printf '  %-50s %s\n' "${module_config}" "ok"
  else
    printf '  %-50s %s\n' "${module_config:-<not found>}" "FAIL: python module missing or not before iterator — DNSBL will not block anything regardless of feed/compile status"
    fail_count=$((fail_count + 1))
  fi
fi

echo
echo "=== DNSBL aliases (action must be 'unbound'; raw download must exist in dnsblorig/) ==="
for entry in "${dnsbl_aliases[@]}"; do
  name="${entry%|*}"
  action="${entry#*|}"
  status="ok"
  if [[ "${action}" != "unbound" ]]; then
    status="FAIL: action='${action}' (must be 'unbound')"
    fail_count=$((fail_count + 1))
  elif ! grep -qi "^${name}" <<< "${dnsblorig_files}"; then
    status="FAIL: no raw download found under dnsblorig/ for ${name}.*"
    fail_count=$((fail_count + 1))
  fi
  printf '  %-32s %s\n' "${name}" "${status}"
done

echo
echo "=== IPv4 deny feeds (compiled output must exist in deny/ as <header>_v4.txt) ==="
for entry in "${ipv4_headers[@]}"; do
  alias_name="${entry%|*}"
  header="${entry#*|}"
  status="ok"
  if ! grep -qix "${header}_v4.txt" <<< "${deny_files}"; then
    status="FAIL: no ${header}_v4.txt in deny/"
    fail_count=$((fail_count + 1))
  fi
  printf '  %-24s %-28s %s\n' "${alias_name}" "${header}" "${status}"
done

echo
if [[ "${fail_count}" -gt 0 ]]; then
  log_die "${fail_count} feed(s) failed validation. See FAIL lines above."
fi
log_info "All SURU_ DNSBL aliases and IPv4 feeds have download/compile evidence on disk."
