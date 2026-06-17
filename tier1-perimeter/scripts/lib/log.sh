#!/usr/bin/env bash
# =============================================================================
# SURU Tier 1 — lib/log.sh
# Structured logger. Sources into deploy.sh and platform drivers.
# Respects VERBOSE and DRY_RUN globals.
#
# stdout vs stderr rules — IMPORTANT
# ===================================
# log_info   → stdout   intentional structured output, safe to pipe/capture
# log_debug  → stderr   MUST NOT pollute $() subshell captures
# log_warn   → stderr   operator warnings
# log_error  → stderr   operator errors
# log_die    → stderr + exit 1
#
# Any log_ function that writes to stdout will corrupt variable captures:
#   result=$(ssh_exec "cmd")   <- captures ALL stdout including log lines
# Always redirect debug/warn/error to stderr.
# =============================================================================

_log()        { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [${1}] ${*:2}"; }
_log_stderr() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [${1}] ${*:2}" >&2; }

log_info()  { _log      INFO  "$*"; }          # stdout — safe to capture
log_warn()  { _log_stderr WARN  "$*"; }        # stderr
log_error() { _log_stderr ERROR "$*"; }        # stderr
log_debug() { ${VERBOSE:-false} && _log_stderr DEBUG "$*" || true; }  # stderr
log_die()   { log_error "$*"; exit 1; }

# run CMD [ARGS...]
# In DRY_RUN mode: prints the command without executing it.
run() {
  if ${DRY_RUN:-false}; then
    _log_stderr DRY-RUN "$*"
  else
    log_debug "Exec: $*"
    "$@"
  fi
}
