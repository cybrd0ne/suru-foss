#!/usr/bin/env bash
# =============================================================================
# SURU Tier 1 — lib/ssh.sh
# Shared SSH / SCP wrappers.
# Requires globals: ROUTER_HOST, ROUTER_SSH_USER, ROUTER_SSH_KEY,
#                   SSH_STRICT_HOST_KEY_CHECKING
#
# FreeBSD / pfSense shell compatibility — IMPORTANT for future maintainers
# =========================================================================
# pfSense sets /bin/tcsh as the login shell for unprivileged SSH users.
#
# PROBLEM 1 — metacharacter handling:
#   tcsh does NOT evaluate POSIX redirects (2>/dev/null) or logic operators
#   (||, &&) when SSH passes a command string as a single argument via exec().
#   Result: 'cat /etc/version 2>/dev/null' → cat: 2: No such file or directory
#
# PROBLEM 2 — stdin stall with multi-token sh -c:
#   ssh ... host sh -c "cmd"  → SSH sends three argv tokens to the remote side.
#   FreeBSD /bin/sh -c "cmd" runs the command but inherits the SSH stdin
#   channel, which stays open (no EOF) → process completes but SSH hangs.
#
# SOLUTION — single-string quoting:
#   ssh ... host 'sh -c "cmd"'
#   Pass the ENTIRE invocation as ONE string to SSH. SSH hands it to the
#   remote login shell as a command string. The login shell execs /bin/sh -c
#   and SSH's non-interactive channel delivers EOF on stdin automatically.
#   All POSIX redirects, pipes, and logic operators work correctly.
#
# RULE: ssh_exec() always wraps CMD as the single string: sh -c "CMD"
#       ssh_exec_raw() passes argv tokens directly — use for pfSsh.php only.
# =============================================================================

# Build SSH options array — avoids fragile $(echo ...) word-split subshell.
_ssh_opts_array() {
  SSH_OPTS=(
    -i "${ROUTER_SSH_KEY}"
    -o "BatchMode=yes"
    -o "ConnectTimeout=15"
    -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING:-yes}"
  )
}

# ssh_exec COMMAND
# Runs COMMAND on the router over SSH.
# Wraps COMMAND as: sh -c "COMMAND" passed as a SINGLE string to SSH.
# This is the correct pattern for FreeBSD/pfSense (tcsh login shell):
#   - Avoids stdin stall from multi-token sh -c
#   - Guarantees POSIX sh semantics for redirects and logic operators
# Single-quotes inside COMMAND must be escaped as '\'' if needed.
ssh_exec() {
  local cmd="$1"
  log_debug "SSH [${ROUTER_SSH_USER}@${ROUTER_HOST}]: ${cmd}"
  if ${DRY_RUN:-false}; then
    _log DRY-RUN "ssh ${ROUTER_SSH_USER}@${ROUTER_HOST} 'sh -c \"${cmd}\"'"
    return 0
  fi
  _ssh_opts_array
  # Pass entire invocation as ONE string — prevents stdin stall on FreeBSD sh
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" \
    "${ROUTER_SSH_USER}@${ROUTER_HOST}" \
    "sh -c \"${cmd}\""
}

# ssh_exec_raw COMMAND [ARGS...]
# Runs COMMAND on the router with discrete argv tokens — NO sh -c wrapping.
# Use ONLY for pfSsh.php invocations where the command is an exec() call
# with its own argument list (pfSsh.php playback svc restart syslog-ng).
# Do NOT use for commands containing shell metacharacters.
ssh_exec_raw() {
  log_debug "SSH raw [${ROUTER_SSH_USER}@${ROUTER_HOST}]: $*"
  if ${DRY_RUN:-false}; then
    _log DRY-RUN "ssh ${ROUTER_SSH_USER}@${ROUTER_HOST} $*"
    return 0
  fi
  _ssh_opts_array
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" \
    "${ROUTER_SSH_USER}@${ROUTER_HOST}" \
    "$@"
}

# ssh_exec_heredoc SCRIPT
# Sends a multi-line script to the router via stdin over SSH (bash -s).
# Used to drive pfSsh.php interactive stdin commands.
ssh_exec_heredoc() {
  local script="$1"
  log_debug "SSH heredoc [${ROUTER_SSH_USER}@${ROUTER_HOST}] ($(printf '%s' "$script" | wc -l) lines)"
  if ${DRY_RUN:-false}; then
    _log DRY-RUN "ssh heredoc to ${ROUTER_SSH_USER}@${ROUTER_HOST}:"
    printf '%s\n' "$script" | sed 's/^/    /'
    return 0
  fi
  _ssh_opts_array
  printf '%s\n' "$script" | ssh "${SSH_OPTS[@]}" \
    "${ROUTER_SSH_USER}@${ROUTER_HOST}" \
    bash -s
}

# scp_push LOCAL REMOTE
# Copies LOCAL file to REMOTE path on the router.
scp_push() {
  local src="$1"
  local dst="$2"
  log_debug "SCP push ${src} → ${ROUTER_SSH_USER}@${ROUTER_HOST}:${dst}"
  if ${DRY_RUN:-false}; then
    _log DRY-RUN "scp ${src} ${ROUTER_SSH_USER}@${ROUTER_HOST}:${dst}"
    return 0
  fi
  _ssh_opts_array
  scp "${SSH_OPTS[@]}" \
    "${src}" \
    "${ROUTER_SSH_USER}@${ROUTER_HOST}:${dst}"
}

# scp_pull REMOTE LOCAL
# Copies REMOTE file from the router to LOCAL path.
scp_pull() {
  local src="$1"
  local dst="$2"
  log_debug "SCP pull ${ROUTER_SSH_USER}@${ROUTER_HOST}:${src} → ${dst}"
  if ${DRY_RUN:-false}; then
    _log DRY-RUN "scp ${ROUTER_SSH_USER}@${ROUTER_HOST}:${src} ${dst}"
    return 0
  fi
  _ssh_opts_array
  scp "${SSH_OPTS[@]}" \
    "${ROUTER_SSH_USER}@${ROUTER_HOST}:${src}" \
    "${dst}"
}
