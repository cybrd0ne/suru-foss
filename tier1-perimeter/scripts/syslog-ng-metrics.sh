#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 1 syslog-ng telemetry
# =============================================================================
# Connects to the Tier 1 router (pfSense) via SSH and reports:
#   --status   Service state and SIEM connectivity
#   --buffer   Disk-buffer queue depth, file size, and ceiling usage
#   --lag      Per-source read lag + delivery lag to SIEM (count, bytes, time)
#
# All three sections are shown when no section flag is given.
#
# Usage:
#   bash scripts/syslog-ng-metrics.sh [OPTIONS]
#
# Options:
#   --status         Service state + SIEM connection counters
#   --buffer         Disk-buffer depth, size, and ceiling %
#   --lag            Source read lag + delivery queue analysis
#   --all            All sections (default when no section flag is given)
#   --json           Emit a single JSON object instead of human-readable text
#   --env FILE       Path to .env file  (default: <tier1>/.env)
#   --verbose        Show raw SSH output and parsed fields
#   -h | --help      Show this help
#
# Environment variables (loaded from .env):
#   ROUTER_HOST, ROUTER_SSH_KEY, ROUTER_SSH_USER,
#   SSH_STRICT_HOST_KEY_CHECKING
#
# MITRE ATT&CK: TA0009 Collection / T1005 — operator visibility into log pipeline
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER1_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${TIER1_DIR}/.env"

# ── Runtime flags ─────────────────────────────────────────────────────────────
SHOW_STATUS=false
SHOW_BUFFER=false
SHOW_LAG=false
OUTPUT_JSON=false
VERBOSE=false
SECTIONS_GIVEN=false

# ── Colour codes ──────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_DIM='\033[2m'

ok()   { printf "${C_GREEN}✓${C_RESET}"; }
warn() { printf "${C_YELLOW}⚠${C_RESET}"; }
err()  { printf "${C_RED}✗${C_RESET}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
die()     { printf "${C_RED}[ERR]${C_RESET} %s\n" "$*" >&2; exit 1; }
verbose() { $VERBOSE && printf "${C_DIM}[dbg] %s${C_RESET}\n" "$*" >&2 || true; }

# human_bytes BYTES — print bytes as human-readable
human_bytes() {
  local b="$1"
  if (( b >= 1073741824 )); then
    awk "BEGIN { printf \"%.1f GB\", $b/1073741824 }"
  elif (( b >= 1048576 )); then
    awk "BEGIN { printf \"%.1f MB\", $b/1048576 }"
  elif (( b >= 1024 )); then
    awk "BEGIN { printf \"%.1f KB\", $b/1024 }"
  else
    printf '%d B' "$b"
  fi
}

# human_duration SECONDS — print seconds as h/m/s
human_duration() {
  local s="$1"
  if (( s < 0 ));  then printf '0s'; return; fi
  if (( s < 60 )); then printf '%ds' "$s"; return; fi
  if (( s < 3600 )); then
    printf '%dm %ds' "$(( s/60 ))" "$(( s%60 ))"
  elif (( s < 86400 )); then
    printf '%dh %dm' "$(( s/3600 ))" "$(( (s%3600)/60 ))"
  else
    printf '%dd %dh' "$(( s/86400 ))" "$(( (s%86400)/3600 ))"
  fi
}

# comma_num N — add thousands separators (BSD/POSIX awk, no GNU sed \B)
comma_num() {
  printf '%d\n' "$1" | awk '{
    s = $0; r = ""
    while (length(s) > 3) {
      r = "," substr(s, length(s)-2) r
      s = substr(s, 1, length(s)-3)
    }
    print s r
  }'
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: bash scripts/syslog-ng-metrics.sh [OPTIONS]

Sections (default: all):
  --status         Service state and SIEM connection counters
  --buffer         Disk-buffer queue depth, size, and ceiling usage
  --lag            Per-source read lag + delivery queue analysis

Output:
  --json           Emit JSON instead of human-readable text
  --verbose        Show raw SSH responses and parsed fields

Environment:
  --env FILE       Path to .env (default: <tier1-perimeter>/.env)

  -h | --help      Show this help
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)  SHOW_STATUS=true;  SECTIONS_GIVEN=true ;;
      --buffer)  SHOW_BUFFER=true;  SECTIONS_GIVEN=true ;;
      --lag)     SHOW_LAG=true;     SECTIONS_GIVEN=true ;;
      --all)     SHOW_STATUS=true; SHOW_BUFFER=true; SHOW_LAG=true; SECTIONS_GIVEN=true ;;
      --json)    OUTPUT_JSON=true ;;
      --verbose) VERBOSE=true ;;
      --env)     [[ $# -gt 1 ]] || die "--env requires a path"; ENV_FILE="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1  (try --help)" ;;
    esac
    shift
  done
  # Default: show everything
  if ! $SECTIONS_GIVEN; then
    SHOW_STATUS=true; SHOW_BUFFER=true; SHOW_LAG=true
  fi
}

# ── Load env ──────────────────────────────────────────────────────────────────
load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    verbose "loaded env from $ENV_FILE"
  else
    verbose ".env not found at $ENV_FILE — using shell environment"
  fi
  [[ -n "${ROUTER_HOST:-}" ]] || die "ROUTER_HOST not set — populate .env or export it"
}

# ── SSH wrapper ───────────────────────────────────────────────────────────────
# Runs a local heredoc script on the router via `sudo sh` reading from stdin.
# pfSense uses tcsh as login shell; piping to 'sudo sh' gives us POSIX sh.
ssh_collect() {
  local user="${ROUTER_SSH_USER:-admin}"
  local host="${ROUTER_HOST}"
  local key="${ROUTER_SSH_KEY:-${HOME}/.ssh/suru_deploy}"

  local strict
  case "$(echo "${SSH_STRICT_HOST_KEY_CHECKING:-}" | tr '[:upper:]' '[:lower:]')" in
    yes|true|strict) strict="yes" ;;
    no|off|none)     strict="no"  ;;
    *)               strict="accept-new" ;;
  esac

  local ssh_opts=(-i "$key"
                  -o "StrictHostKeyChecking=${strict}"
                  -o "BatchMode=yes"
                  -o "ConnectTimeout=10"
                  -o "LogLevel=ERROR")

  verbose "ssh ${user}@${host} (key=${key})"

  # Send the collection script via stdin so quoting never hits tcsh.
  # Each section delimited by ===SECTION=== for local parsing.
  ssh "${ssh_opts[@]}" "${user}@${host}" 'sudo sh' <<'REMOTE_SCRIPT'
printf '===STATS===\n'
syslog-ng-ctl stats 2>/dev/null || printf 'ERR_STATS\n'

printf '===DQTOOL===\n'
dqtool info /var/db/syslog-ng-00000.rqf 2>/dev/null || printf 'number_of_messages=0\n'

printf '===TIME===\n'
date +%s

printf '===QFILE===\n'
# FreeBSD stat: %m = mtime epoch, %z = size bytes
stat -f '%m %z' /var/db/syslog-ng-00000.rqf 2>/dev/null || printf '0 0\n'

printf '===SVCSTATUS===\n'
pfSsh.php playback svc status syslog-ng 2>/dev/null || printf 'unknown\n'

printf '===END===\n'
REMOTE_SCRIPT
}

# ── Parse helpers (awk-based for shellcheck safety) ──────────────────────────

# stat_field DATA MATCH TYPE — get a single numeric field from syslog-ng stats
# E.g.: stat_field "$stats" "d_siem_tls" "written"
stat_field() {
  local data="$1" match="$2" field="$3"
  printf '%s\n' "$data" | awk -F';' -v m="$match" -v f="$field" \
    '$0 ~ m && $5 == f { v=$6 } END { print (v+0) }'
}

# stat_string DATA MATCH TYPE — like stat_field but returns string, not number
stat_string() {
  local data="$1" match="$2" field="$3"
  printf '%s\n' "$data" | awk -F';' -v m="$match" -v f="$field" \
    '$0 ~ m && $5 == f { print $6; exit }'
}

# source_stamps DATA — print "LABEL STAMP" lines for active file sources
# Returns only sources with stamp > 0 (have processed at least one message).
# Uses POSIX awk (no 3-arg match; no GNU extensions).
source_stamps() {
  local data="$1"
  printf '%s\n' "$data" | awk -F';' '
    $1 == "src.file" && $5 == "stamp" && $6+0 > 0 {
      path = $3
      # Extract basename without extension
      n = split(path, parts, "/")
      base = parts[n]
      sub(/\.[^.]+$/, "", base)
      # Build a readable label
      if (index(path, "suricata") > 0 && index(path, "eve.json") > 0)
        label = "suricata-eve"
      else if (index(path, "/zeek/") > 0)
        label = "zeek-" base
      else
        label = base
      printf "%s %s\n", label, $6
    }
  '
}

# extract_section RAW SECTION_NAME — extract text between ===NAME=== markers
extract_section() {
  local raw="$1" name="$2"
  printf '%s\n' "$raw" | awk \
    -v start="===${name}===" \
    -v end_pat='===.*===' \
    'found && $0 ~ end_pat { exit }
     found { print }
     $0 == start { found=1 }'
}

# ── Output: human-readable ────────────────────────────────────────────────────
print_header() {
  local host="$1" ts="$2"
  local dt; dt=$(date -r "$ts" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -d "@${ts}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || printf '%s' "$ts")
  printf '\n'
  printf "${C_BOLD}══════════════════════════════════════════════════${C_RESET}\n"
  printf "${C_BOLD}  SURU Tier 1 — syslog-ng Metrics${C_RESET}\n"
  printf "  Router: ${C_CYAN}%s${C_RESET}  │  %s\n" "$host" "$dt"
  printf "${C_BOLD}══════════════════════════════════════════════════${C_RESET}\n"
}

print_status() {
  local stats="$1" svc="$2"
  printf '\n%bSERVICE%b\n' "${C_BOLD}" "${C_RESET}"

  # Service status
  local svc_state
  if printf '%s\n' "$svc" | grep -qi 'running'; then
    svc_state="$(ok) running"
  elif printf '%s\n' "$svc" | grep -qi 'stopped'; then
    svc_state="$(err) stopped"
  else
    svc_state="$(warn) unknown"
  fi
  printf "  %-22s %b\n" "Status" "$svc_state"

  # SIEM destination — derive address from stats instance field (e.g. "tls,syslog.suru.local:443")
  local siem_addr; siem_addr=$(printf '%s\n' "$stats" | awk -F';' '/d_siem_tls#0/ { print $3; exit }')
  [[ -n "$siem_addr" ]] && printf "  %-22s %s\n" "SIEM" "$siem_addr"

  # Counters
  local written dropped
  written=$(stat_field "$stats" "d_siem_tls#0" "written")
  dropped=$(stat_field "$stats" "d_siem_tls#0" "dropped")

  printf "  %-22s %s messages\n" "Total delivered" "$(comma_num "${written:-0}")"
  if [[ "${dropped:-0}" -eq 0 ]]; then
    printf "  %-22s %s  %b\n" "Dropped" "0" "$(ok)"
  else
    printf "  %-22s %s  %b\n" "Dropped" "$(comma_num "$dropped")" "$(err) MESSAGES LOST"
  fi

  # Write rate
  local eps_1h eps_24h
  eps_1h=$(stat_string  "$stats" "d_siem_tls#0" "eps_last_1h")
  eps_24h=$(stat_string "$stats" "d_siem_tls#0" "eps_last_24h")
  local rate_icon
  if awk "BEGIN { exit (${eps_1h:-0} > 0) ? 0 : 1 }"; then
    rate_icon="$(ok)"
  else
    rate_icon="$(warn) SIEM not receiving"
  fi
  printf "  %-22s %.1f eps (1h)  /  %.1f eps (24h)  %b\n" \
    "Write rate" "${eps_1h:-0}" "${eps_24h:-0}" "$rate_icon"
}

print_buffer() {
  local stats="$1" dqinfo="$2" qfile_stat="$3"
  printf '\n%bDISK BUFFER%b\n' "${C_BOLD}" "${C_RESET}"

  # Queue file age and size
  local qfile_mtime qfile_size
  qfile_mtime=$(printf '%s\n' "$qfile_stat" | awk '{print $1}')
  qfile_size=$(printf '%s\n' "$qfile_stat" | awk '{printf "%d", $2+0}')

  # Message count from dqtool
  local msg_count=0
  if printf '%s\n' "$dqinfo" | grep -q 'number_of_messages'; then
    msg_count=$(printf '%s\n' "$dqinfo" | \
      awk -F"'" '/number_of_messages/ { print $4+0 }')
  fi

  # Bytes queued from syslog-ng stats
  local queued_bytes
  queued_bytes=$(stat_field "$stats" "d_siem_tls#0" "queued")

  # Queue file size vs 5GB ceiling
  local ceiling_bytes=5368709120
  local used_pct=0
  if [[ "${qfile_size:-0}" -gt 0 ]]; then
    used_pct=$(awk "BEGIN { printf \"%.1f\", (${qfile_size}/${ceiling_bytes})*100 }")
  fi

  printf "  %-22s %s  (%s messages)\n" \
    "Queue depth" "$(human_bytes "${queued_bytes:-0}")" "$(comma_num "${msg_count:-0}")"
  printf "  %-22s %s / %s  (%s%%)\n" \
    "Queue file size" \
    "$(human_bytes "${qfile_size:-0}")" \
    "$(human_bytes $ceiling_bytes)" \
    "${used_pct}"

  if [[ "${qfile_mtime:-0}" -gt 0 ]]; then
    local now_epoch; now_epoch=$(date +%s)
    local age=$(( now_epoch - qfile_mtime ))
    printf "  %-22s /var/db/syslog-ng-00000.rqf  (last write: %s ago)\n" \
      "Queue file" "$(human_duration "$age")"
  else
    printf "  %-22s not found  %b\n" "Queue file" "$(warn) syslog-ng not buffering"
  fi
}

print_lag() {
  local stats="$1" dqinfo="$2" now="$3"
  printf '\n%bSOURCE LAG%b  (time since last event read per source)\n' "${C_BOLD}" "${C_RESET}"

  local max_lag=0
  local any_source=false

  while IFS=' ' read -r label stamp; do
    any_source=true
    local age=$(( now - stamp ))
    [[ $age -lt 0 ]] && age=0
    [[ $age -gt $max_lag ]] && max_lag=$age
    local icon
    if   (( age <   60 )); then icon="$(ok)"
    elif (( age < 3600 )); then icon="$(warn)"
    else                        icon="$(err)"
    fi
    printf "  %-24s %s  %b\n" "$label" "$(human_duration "$age")" "$icon"
  done < <(source_stamps "$stats")

  $any_source || printf "  (no active file sources with processed messages)\n"

  printf '\n%bDELIVERY LAG%b\n' "${C_BOLD}" "${C_RESET}"

  local written queued_bytes msg_count eps_1h eps_24h
  written=$(stat_field      "$stats" "d_siem_tls#0" "written")
  queued_bytes=$(stat_field "$stats" "d_siem_tls#0" "queued")
  eps_1h=$(stat_string      "$stats" "d_siem_tls#0" "eps_last_1h")
  eps_24h=$(stat_string     "$stats" "d_siem_tls#0" "eps_last_24h")

  msg_count=0
  if printf '%s\n' "$dqinfo" | grep -q 'number_of_messages'; then
    msg_count=$(printf '%s\n' "$dqinfo" | \
      awk -F"'" '/number_of_messages/ { print $4+0 }')
  fi

  local eps; eps="${eps_1h:-0}"

  printf "  %-24s %s messages  (%s)\n" \
    "Queued in buffer" \
    "$(comma_num "${msg_count:-0}")" \
    "$(human_bytes "${queued_bytes:-0}")"

  if awk "BEGIN { exit (${eps} > 0) ? 0 : 1 }"; then
    # SIEM is receiving — calculate drain time
    local drain_secs
    drain_secs=$(awk "BEGIN {
      eps = ${eps}+0; q = ${msg_count}+0
      if (eps > 0 && q > 0) printf \"%d\", q/eps
      else printf \"0\"
    }")
    if [[ "$drain_secs" -gt 0 ]]; then
      printf "  %-24s %.1f eps  %b\n" "SIEM write rate" "$eps" "$(ok)"
      printf "  %-24s ~%s at current rate\n" "Estimated drain" "$(human_duration "$drain_secs")"
    else
      printf "  %-24s %.1f eps  %b  (buffer drained)\n" "SIEM write rate" "$eps" "$(ok)"
    fi
  else
    printf "  %-24s 0.0 eps  %b\n" "SIEM write rate" "$(warn) SIEM unreachable or idle"
    if [[ "${msg_count:-0}" -gt 0 ]]; then
      printf "  %-24s buffer will drain when SIEM reconnects\n" "Drain"
      # Estimate time behind using 24h rate if available
      if awk "BEGIN { exit (${eps_24h:-0} > 0) ? 0 : 1 }"; then
        local drain_est
        drain_est=$(awk "BEGIN { printf \"%d\", ${msg_count}/${eps_24h} }")
        printf "  %-24s ~%s  (based on 24h rate of %.0f eps)\n" \
          "Drain estimate" "$(human_duration "$drain_est")" "${eps_24h}"
      fi
    fi
  fi

  # Time-behind summary — only shown when lag is meaningful (>60s) or buffer non-empty
  if [[ $max_lag -gt 60 ]] || [[ "${msg_count:-0}" -gt 0 ]]; then
    printf '\n  %b OVERALL LAG SUMMARY\n' "$(warn)"
    printf "  Source read lag:  %s (most lagged source)\n" "$(human_duration "$max_lag")"
    printf "  Delivery backlog: %s messages\n" "$(comma_num "${msg_count:-0}")"
    # Days behind estimate
    local day_est=0
    if awk "BEGIN { exit (${eps_24h:-0} > 0) ? 0 : 1 }"; then
      day_est=$(awk "BEGIN { printf \"%.1f\", ${msg_count}/(${eps_24h}*86400) }")
      printf "  Behind by:        ~%s days of log volume\n" "$day_est"
    fi
  else
    printf '\n  %b  All sources current, buffer empty — delivery live\n' "$(ok)"
  fi
}

# ── Output: JSON ──────────────────────────────────────────────────────────────
print_json() {
  local stats="$1" dqinfo="$2" qfile_stat="$3" svc="$4" now="$5"

  local written dropped queued_bytes eps_1h eps_24h msg_count
  local qfile_mtime qfile_size svc_running

  written=$(stat_field      "$stats" "d_siem_tls#0" "written")
  dropped=$(stat_field      "$stats" "d_siem_tls#0" "dropped")
  queued_bytes=$(stat_field "$stats" "d_siem_tls#0" "queued")
  eps_1h=$(stat_string      "$stats" "d_siem_tls#0" "eps_last_1h")
  eps_24h=$(stat_string     "$stats" "d_siem_tls#0" "eps_last_24h")
  qfile_mtime=$(printf '%s\n' "$qfile_stat" | awk '{print $1}')
  qfile_size=$(printf '%s\n' "$qfile_stat" | awk '{printf "%d", $2+0}')
  msg_count=0
  if printf '%s\n' "$dqinfo" | grep -q 'number_of_messages'; then
    msg_count=$(printf '%s\n' "$dqinfo" | awk -F"'" '/number_of_messages/ { print $4+0 }')
  fi
  printf '%s\n' "$svc" | grep -qi 'running' && svc_running=true || svc_running=false

  local max_src_lag=0
  while IFS=' ' read -r _ stamp; do
    local age=$(( now - stamp ))
    [[ $age -gt $max_src_lag ]] && max_src_lag=$age
  done < <(source_stamps "$stats")

  local drain_secs=0
  if awk "BEGIN { exit (${eps_1h:-0} > 0) ? 0 : 1 }"; then
    drain_secs=$(awk "BEGIN { eps=${eps_1h}+0; q=${msg_count}+0; printf \"%d\", (eps>0&&q>0)?q/eps:0 }")
  fi

  cat <<EOF
{
  "timestamp": ${now},
  "router": "${ROUTER_HOST}",
  "service": {
    "running": ${svc_running},
    "delivered_total": ${written:-0},
    "dropped_total": ${dropped:-0},
    "write_eps_1h": ${eps_1h:-0},
    "write_eps_24h": ${eps_24h:-0}
  },
  "buffer": {
    "messages_queued": ${msg_count:-0},
    "bytes_queued": ${queued_bytes:-0},
    "queue_file_size_bytes": ${qfile_size:-0},
    "queue_file_mtime": ${qfile_mtime:-0},
    "queue_ceiling_bytes": 5368709120
  },
  "lag": {
    "max_source_read_lag_seconds": ${max_src_lag},
    "queued_messages": ${msg_count:-0},
    "estimated_drain_seconds": ${drain_secs}
  }
}
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  load_env

  # Validate SSH key exists
  local key="${ROUTER_SSH_KEY:-${HOME}/.ssh/suru_deploy}"
  [[ -f "$key" ]] || die "SSH key not found: $key  (set ROUTER_SSH_KEY in .env)"

  # Collect all metrics in one SSH session
  local raw
  raw=$(ssh_collect) || die "SSH to ${ROUTER_HOST} failed — check ROUTER_HOST and SSH key"
  verbose "raw output:\n${raw}"

  # Extract sections
  local stats svc_raw dqinfo_raw qfile_raw now
  stats=$(extract_section   "$raw" "STATS")
  svc_raw=$(extract_section "$raw" "SVCSTATUS")
  dqinfo_raw=$(extract_section "$raw" "DQTOOL")
  qfile_raw=$(extract_section  "$raw" "QFILE")
  now=$(extract_section        "$raw" "TIME" | tr -d '[:space:]')

  verbose "parsed STATS lines: $(printf '%s\n' "$stats" | wc -l | tr -d ' ')"
  verbose "parsed DQTOOL: $dqinfo_raw"
  verbose "parsed QFILE: $qfile_raw"
  verbose "parsed NOW: $now"

  # Sanity check
  [[ -n "$now" && "$now" =~ ^[0-9]+$ ]] || die "Could not parse router timestamp — SSH succeeded but output is unexpected"

  # JSON mode
  if $OUTPUT_JSON; then
    print_json "$stats" "$dqinfo_raw" "$qfile_raw" "$svc_raw" "$now"
    exit 0
  fi

  # Human-readable mode
  print_header "${ROUTER_HOST}" "$now"

  if $SHOW_STATUS; then print_status "$stats" "$svc_raw";               fi
  if $SHOW_BUFFER; then print_buffer "$stats" "$dqinfo_raw" "$qfile_raw"; fi
  if $SHOW_LAG;    then print_lag    "$stats" "$dqinfo_raw" "$now";       fi

  printf '\n'
}

main "$@"
