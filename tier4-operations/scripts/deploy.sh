#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 4 Operations  ·  deploy.sh
# =============================================================================
# Orchestrates the Tier 4 stacks (monitoring + frontdoor). Mirrors the UX of
# tier3-core/scripts/deploy.sh: subcommands, --group/--service/--env flags,
# --dry-run and --verbose modifiers, an access-summary printer.
#
# Tier 4 owns:
#   - monitoring/      InfluxDB · Prometheus · Grafana · Watchdog
#   - frontdoor/proxy/ nginx reverse proxy + stream LB (sole LAN entry point)
#
# Tier 4 attaches to the external network `suru-t3-core-internal` owned by
# tier3-core; bring up tier3-core/scripts/deploy.sh first.
# =============================================================================
set -euo pipefail
trap '_on_error $LINENO' ERR
_on_error() { log ERROR "Script failed on line $1 — re-run with --verbose for details"; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER4_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${TIER4_DIR}/.env"

# ── Runtime flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
SKIP_DNS=false
COMMAND=""
TARGET_GROUP=""
TARGET_SERVICE=""

# ── Compose groups (startup order; teardown is reversed) ─────────────────────
# Monitoring brings up the observability stack first; frontdoor depends on
# Grafana/Prometheus aliases on `suru-t3-core-internal` being reachable.
ALL_GROUPS=(
  "monitoring"       # InfluxDB + Prometheus + Grafana + watchdog
  "frontdoor/proxy"  # nginx reverse proxy + stream LB
)

# ── Colour codes ──────────────────────────────────────────────────────────────
C_RESET="\033[0m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[0;36m"
C_BOLD="\033[1m"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
  local level="$1"; shift; local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"
  case "$level" in
    INFO)  printf "${C_CYAN}[%s] [INFO]${C_RESET}  %s\n"  "$ts" "$*" ;;
    OK)    printf "${C_GREEN}[%s] [ OK ]${C_RESET}  %s\n" "$ts" "$*" ;;
    WARN)  printf "${C_YELLOW}[%s] [WARN]${C_RESET}  %s\n" "$ts" "$*" ;;
    ERROR) printf "${C_RED}[%s] [ERR ]${C_RESET}  %s\n"  "$ts" "$*" >&2 ;;
    STEP)  printf "\n${C_BOLD}━━━ %s ━━━${C_RESET}\n" "$*" ;;
  esac
}

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  printf "${C_BOLD}SURU Platform — Tier 4 Deployment Tool${C_RESET}\n\n"
  printf "${C_BOLD}USAGE${C_RESET}\n"
  printf "  deploy.sh <command> [--group <group>] [options]\n\n"
  printf "${C_BOLD}COMMANDS${C_RESET}\n"
  printf "  %-18s %s\n" "deploy"          "Full deployment: certs → all groups → check → DNS register (if REGISTER_DNS_ON_DEPLOY)"
  printf "  %-18s %s\n" "start"           "Start all groups (or one with --group)"
  printf "  %-18s %s\n" "stop"            "Stop all groups (or one with --group), reverse order"
  printf "  %-18s %s\n" "restart"         "Stop then start; re-registers DNS if REGISTER_DNS_ON_DEPLOY and frontdoor in scope"
  printf "  %-18s %s\n" "destroy"         "Remove containers and networks; keep data volumes"
  printf "  %-18s %s\n" "destroy-all"     "Remove containers, networks AND volumes  ⚠️  irreversible"
  printf "  %-18s %s\n" "status"          "Print health/status table for all containers"
  printf "  %-18s %s\n" "check"           "API-level health probes (frontdoor, Grafana, Prometheus, InfluxDB)"
  printf "  %-18s %s\n" "logs"            "Tail logs for all groups or one service (--service <name>)"
  printf "  %-18s %s\n" "certs"           "Generate the frontdoor TLS cert (signed by SURU root CA)"
  printf "  %-18s %s\n" "reload"          "Reload nginx config (after editing routes.yaml + re-render)"
  printf "  %-18s %s\n" "register-dns"    "Register FRONTDOOR_FQDN -> FRONTDOOR_IP on the perimeter router DNS"
  printf "  %-18s %s\n" "unregister-dns"  "Remove the frontdoor DNS host override from the perimeter router"
  printf "  %-18s %s\n" "check-env"       "Validate cross-tier .env consistency and DNS alignment"
  printf "  %-18s %s\n" "configure-host"  "Deploy Docker daemon.json + BuildKit GC policy to local or T3 host"
  printf "\n${C_BOLD}GROUPS${C_RESET}  (use with --group)\n"
  for g in "${ALL_GROUPS[@]}"; do
    local compose_file="${TIER4_DIR}/${g}/compose.yaml"
    local exists="[compose.yaml present]"
    [[ -f "$compose_file" ]] || exists="${C_YELLOW}[compose.yaml not found]${C_RESET}"
    printf "  %-26s %b\n" "$g" "$exists"
  done
  printf "\n${C_BOLD}OPTIONS${C_RESET}\n"
  printf "  %-30s %s\n" "--group <group>"            "Scope start / stop / restart / deploy / destroy to one group"
  printf "  %-30s %s\n" "--service <name>"           "Scope logs or check to a single container name"
  printf "  %-30s %s\n" "--env <file>"               "Path to .env file  (default: <tier4>/.env)"
  printf "  %-30s %s\n" "--skip-dns"                 "Skip the DNS register/unregister step on deploy/destroy"
  printf "  %-30s %s\n" "--dry-run"                  "Print commands without executing"
  printf "  %-30s %s\n" "--verbose"                  "Extra output (command echo, wait progress)"
  printf "  %-30s %s\n" "-h | --help"                "Show this help"
  printf "\n${C_BOLD}EXAMPLES${C_RESET}\n"
  printf "  # First-time full deployment (after tier3-core is up):\n"
  printf "  bash deploy.sh deploy --verbose\n\n"
  printf "  # Bring up only the frontdoor:\n"
  printf "  bash deploy.sh start --group frontdoor/proxy\n\n"
  printf "  # Tail logs for the frontdoor proxy:\n"
  printf "  bash deploy.sh logs --service suru.t4.frontdoor.proxy\n\n"
  printf "  # Health check only:\n"
  printf "  bash deploy.sh check\n\n"
  printf "  # Reload nginx after editing routes.yaml:\n"
  printf "  bash deploy.sh reload\n\n"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 0; }
  COMMAND="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)        DRY_RUN=true ;;
      --verbose)        VERBOSE=true ;;
      --skip-dns)       SKIP_DNS=true ;;
      --env)            ENV_FILE="$2"; shift ;;
      --group)          TARGET_GROUP="$2"; shift ;;
      --service)        TARGET_SERVICE="$2"; shift ;;
      -h|--help)        usage; exit 0 ;;
      *) log WARN "Unknown option: $1" ;;
    esac
    shift
  done

  if [[ -n "$TARGET_GROUP" ]]; then
    local valid=false
    for g in "${ALL_GROUPS[@]}"; do
      [[ "$g" == "$TARGET_GROUP" ]] && valid=true && break
    done
    if ! $valid; then
      log ERROR "Unknown group: '${TARGET_GROUP}'"
      log ERROR "Valid groups: ${ALL_GROUPS[*]}"
      exit 1
    fi
  fi
}

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  log STEP "Checking dependencies"
  local missing=0
  for cmd in docker openssl curl; do
    if command -v "$cmd" >/dev/null 2>&1; then
      $VERBOSE && log OK "$cmd → $(command -v "$cmd")"
    else
      log ERROR "$cmd not found — please install it"; missing=$((missing + 1))
    fi
  done
  local compose_ver
  compose_ver="$(docker compose version 2>/dev/null || true)"
  if ! echo "$compose_ver" | grep -qE "v[2-9]\.|v[1-9][0-9]\."; then
    log ERROR "Docker Compose v2+ required (docker compose, not docker-compose)"
    log ERROR "Detected: ${compose_ver:-not found}"; missing=$((missing + 1))
  else
    $VERBOSE && log OK "Docker Compose $(echo "$compose_ver" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
  fi
  [[ $missing -gt 0 ]] && { log ERROR "$missing dependency/ies missing — aborting"; exit 1; }
  log OK "All dependencies satisfied"
}

# ── Load env ──────────────────────────────────────────────────────────────────
load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    # NOTE: use `if`, not `$VERBOSE && log …`. As the last statement of this
    # function the bare AND-list would make load_env return $VERBOSE's status —
    # 1 when VERBOSE=false — and under `set -e` that aborts every non-verbose
    # caller (e.g. `deploy.sh check`) right after it calls load_env.
    if $VERBOSE; then log OK "Loaded env from $ENV_FILE"; fi
  else
    log WARN ".env not found at $ENV_FILE — using shell environment only"
  fi
}

# ── Run or dry-run ────────────────────────────────────────────────────────────
run() {
  if $DRY_RUN; then printf "${C_YELLOW}[DRY-RUN]${C_RESET} %s\n" "$*"
  else $VERBOSE && printf "${C_CYAN}[CMD]${C_RESET} %s\n" "$*"; "$@"; fi
}

# ── Compose helper ────────────────────────────────────────────────────────────
compose_cmd() {
  local group="$1"; shift
  local compose_file="${TIER4_DIR}/${group}/compose.yaml"
  if [[ ! -f "$compose_file" ]]; then
    log ERROR "compose.yaml not found: $compose_file"; return 1
  fi
  run docker compose --env-file "$ENV_FILE" --file "$compose_file" "$@"
}

# ── Resolve groups: all or just TARGET_GROUP ──────────────────────────────────
resolve_groups() {
  local _out="$1"
  if [[ -n "$TARGET_GROUP" ]]; then
    eval "${_out}=(\"\$TARGET_GROUP\")"
  else
    eval "${_out}=(\"\${ALL_GROUPS[@]}\")"
  fi
}

resolve_groups_reversed() {
  local _out="$1"
  local _groups=()
  if [[ -n "$TARGET_GROUP" ]]; then
    _groups=("$TARGET_GROUP")
  else
    _groups=("${ALL_GROUPS[@]}")
  fi
  local _reversed=()
  for (( i=${#_groups[@]}-1; i>=0; i-- )); do _reversed+=("${_groups[$i]}"); done
  eval "${_out}=(\"\${_reversed[@]}\")"
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: certs
# ═════════════════════════════════════════════════════════════════════════════
cmd_certs() {
  log STEP "Generating frontdoor TLS cert"

  # ── Ensure the SURU root CA exists (first-time bootstrap) ─────────────────
  local ca_dir="${TIER4_DIR}/pki/certs"
  local ca_script="${TIER4_DIR}/pki/scripts/generate-certs.sh"
  if [[ ! -f "${ca_dir}/root-ca.pem" && ! -f "${ca_dir}/root-ca-key.pem" ]]; then
    # Neither cert nor key exists — genuine first-time bootstrap on a fresh machine.
    log WARN "SURU root CA not found in ${ca_dir} — generating for the first time"
    if [[ ! -x "$ca_script" ]]; then
      log ERROR "PKI bootstrap script not found or not executable: ${ca_script}"
      log ERROR "Create it or place root-ca.pem + root-ca-key.pem in ${ca_dir} manually"
      exit 1
    fi
    local ca_flags=()
    $DRY_RUN  && ca_flags+=("--dry-run")
    $VERBOSE  && ca_flags+=("--verbose")
    run bash "$ca_script" "${ca_flags[@]+"${ca_flags[@]}"}"
    $DRY_RUN || log OK "Root CA generated in ${ca_dir}"
  elif [[ -f "${ca_dir}/root-ca.pem" && ! -f "${ca_dir}/root-ca-key.pem" ]]; then
    # Cert is committed (normal — keys are gitignored) but key is missing.
    # This is NOT a first-time bootstrap — regenerating would silently rotate the CA
    # and invalidate every service cert on every tier. Operator must restore the key.
    log ERROR "root-ca.pem found but root-ca-key.pem is missing in ${ca_dir}."
    log ERROR "DO NOT re-run generate-certs.sh — that would silently rotate the Root CA"
    log ERROR "and break mTLS across all tiers. Restore root-ca-key.pem from your"
    log ERROR "secure backup (SOPS/age vault, Keychain, or encrypted offsite copy)."
    log ERROR "See tier4-operations/pki/README.md for recovery steps."
    exit 1
  else
    $VERBOSE && log OK "Root CA present in ${ca_dir}"
  fi

  local cert_script="${TIER4_DIR}/frontdoor/proxy/scripts/generate-frontdoor-cert.sh"
  [[ -x "$cert_script" ]] || { log ERROR "$cert_script not executable"; exit 1; }
  local flags=()
  $DRY_RUN && flags+=("--dry-run")
  $VERBOSE && flags+=("--verbose")
  run bash "$cert_script" "${flags[@]+"${flags[@]}"}"
  log OK "Frontdoor cert ready in ${TIER4_DIR}/frontdoor/proxy/certs/"
}

# ═════════════════════════════════════════════════════════════════════════════
# HELPER: check_docker_host_config  (non-blocking preflight)
# ═════════════════════════════════════════════════════════════════════════════
check_docker_host_config() {
  log STEP "Preflight: Docker host configuration"

  local src_daemon="${TIER4_DIR}/docker/daemon.json"
  local src_buildkitd="${TIER4_DIR}/docker/buildkitd.toml"
  local warn=0

  case "$(uname -s)" in
    Darwin)
      # macOS: use daemon-macos.json (log settings only — storage-driver and
      # live-restore are unsupported by Docker Desktop and crash the daemon)
      local src_macos="${TIER4_DIR}/docker/daemon-macos.json"
      local dst_daemon="${HOME}/.docker/daemon.json"
      if [[ ! -f "$dst_daemon" ]]; then
        log WARN "${dst_daemon} not present — run: bash deploy.sh configure-host"
        warn=$((warn + 1))
      elif ! diff <(jq -S . "$src_macos" 2>/dev/null) <(jq -S . "$dst_daemon" 2>/dev/null) >/dev/null 2>&1; then
        # Docker Desktop rewrites daemon.json with reordered keys; use jq -S
        # (sorted output) for semantic comparison instead of byte-exact cmp.
        log WARN "${dst_daemon} differs from managed config — run: bash deploy.sh configure-host"
        $VERBOSE && diff <(jq -S . "$src_macos") <(jq -S . "$dst_daemon") || true
        warn=$((warn + 1))
      else
        log OK "daemon.json matches managed config (${dst_daemon})"
      fi
      log INFO "buildkitd.toml check skipped — Docker Desktop manages BuildKit GC internally"
      [[ $warn -gt 0 ]] && log WARN "Docker host config not applied — deploy continues with daemon defaults"
      return 0
      ;;
  esac

  if [[ ! -f /etc/docker/daemon.json ]]; then
    log WARN "/etc/docker/daemon.json not present — run: bash deploy.sh configure-host"
    warn=$((warn + 1))
  elif ! cmp -s "$src_daemon" /etc/docker/daemon.json; then
    log WARN "/etc/docker/daemon.json differs from managed config — run: bash deploy.sh configure-host"
    $VERBOSE && diff -- "$src_daemon" /etc/docker/daemon.json || true
    warn=$((warn + 1))
  else
    log OK "daemon.json matches managed config"
  fi

  if [[ ! -f /etc/buildkit/buildkitd.toml ]]; then
    log WARN "/etc/buildkit/buildkitd.toml not present — run: bash deploy.sh configure-host"
    warn=$((warn + 1))
  elif ! cmp -s "$src_buildkitd" /etc/buildkit/buildkitd.toml; then
    log WARN "/etc/buildkit/buildkitd.toml differs from managed config — run: bash deploy.sh configure-host"
    $VERBOSE && diff -- "$src_buildkitd" /etc/buildkit/buildkitd.toml || true
    warn=$((warn + 1))
  else
    log OK "buildkitd.toml matches managed config"
  fi

  [[ $warn -gt 0 ]] && log WARN "Docker host config not applied — deploy continues with daemon defaults"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: register-dns / unregister-dns
# ═════════════════════════════════════════════════════════════════════════════
# Both delegate to scripts/register-dns.sh, which talks to the perimeter
# router via the existing tier1 pfREST integration.
# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: configure-host
# ═════════════════════════════════════════════════════════════════════════════
# Deploys daemon.json + buildkitd.toml to the local Docker host via a
# one-shot Compose service. No SSH — runs entirely on this machine.
# Restart Docker afterward for changes to take effect.
cmd_configure_host() {
  local src_daemon="${TIER4_DIR}/docker/daemon.json"
  local src_buildkitd="${TIER4_DIR}/docker/buildkitd.toml"

  case "$(uname -s)" in
    Darwin)
      # Docker Desktop on macOS reads ~/.docker/daemon.json.
      # Use daemon-macos.json (log settings only) — storage-driver and
      # live-restore are unsupported by Docker Desktop and crash the daemon.
      log STEP "Configuring Docker Desktop (macOS)"
      local src_macos="${TIER4_DIR}/docker/daemon-macos.json"
      local dst_daemon="${HOME}/.docker/daemon.json"
      run mkdir -p "${HOME}/.docker"
      run cp -- "$src_macos" "$dst_daemon"
      log OK "daemon-macos.json deployed to ${dst_daemon}"
      log INFO "buildkitd.toml skipped — Docker Desktop manages BuildKit GC internally"
      log WARN "Restart Docker Desktop to activate: quit and reopen from the menu bar"
      log WARN "  or: osascript -e 'quit app \"Docker\"' && sleep 3 && open -a Docker"
      return 0
      ;;
  esac

  # Linux — deploy via one-shot Compose service that bind-mounts /etc/docker
  log STEP "Configuring local Docker host (daemon.json + buildkitd.toml)"
  local compose_file="${TIER4_DIR}/docker/compose.yaml"
  [[ -f "$compose_file" ]] || { log ERROR "docker/compose.yaml not found: $compose_file"; exit 1; }
  run docker compose --file "$compose_file" run --rm suru.t4.docker-host-init
  log OK "Docker host configuration deployed"
  log WARN "Restart Docker to activate: sudo systemctl restart docker"
  log WARN "live-restore=true is enabled — containers survive daemon restart."
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: check-env
# ═════════════════════════════════════════════════════════════════════════════
cmd_check_env() {
  local helper="${SCRIPT_DIR}/check-env-consistency.sh"
  [[ -x "$helper" ]] || { log ERROR "check-env-consistency.sh not found or not executable: $helper"; exit 1; }
  local flags=()
  $DRY_RUN && flags+=(--dry-run)
  $VERBOSE && flags+=(--verbose)
  run bash "$helper" "${flags[@]+"${flags[@]}"}"
}

cmd_register_dns() {
  if $SKIP_DNS; then
    log WARN "--skip-dns set; skipping DNS registration"; return 0
  fi
  log STEP "Registering ${FRONTDOOR_FQDN:-suru.local} -> ${FRONTDOOR_IP:-?} on perimeter router DNS"
  local helper="${SCRIPT_DIR}/register-dns.sh"
  [[ -x "$helper" ]] || { log ERROR "$helper not executable"; exit 1; }
  local flags=()
  $DRY_RUN && flags+=("--dry-run")
  $VERBOSE && flags+=("--verbose")
  run bash "$helper" register "${flags[@]+"${flags[@]}"}"
}

cmd_unregister_dns() {
  if $SKIP_DNS; then
    log WARN "--skip-dns set; skipping DNS un-registration"; return 0
  fi
  log STEP "Removing ${FRONTDOOR_FQDN:-suru.local} from perimeter router DNS"
  local helper="${SCRIPT_DIR}/register-dns.sh"
  [[ -x "$helper" ]] || { log ERROR "$helper not executable"; exit 1; }
  local flags=()
  $DRY_RUN && flags+=("--dry-run")
  $VERBOSE && flags+=("--verbose")
  run bash "$helper" unregister "${flags[@]+"${flags[@]}"}"
}

# maybe_register_dns — call from any deploy/restart path that touches the
# frontdoor. Self-gating: no-ops when REGISTER_DNS_ON_DEPLOY is unset,
# when --skip-dns is given, or when a targeted deploy targets a non-frontdoor
# group. Mirrors the destroy-side guard so register/unregister are symmetric.
maybe_register_dns() {
  [[ "${REGISTER_DNS_ON_DEPLOY:-false}" =~ ^(true|yes|1)$ ]] || return 0
  $SKIP_DNS && { log INFO "REGISTER_DNS_ON_DEPLOY set but --skip-dns given; skipping"; return 0; }
  [[ -z "$TARGET_GROUP" || "$TARGET_GROUP" == "frontdoor/proxy" ]] || return 0
  if ! cmd_register_dns; then
    log WARN "════════════════════════════════════════════════════════"
    log WARN "DNS registration FAILED — frontdoor is up but"
    log WARN "${FRONTDOOR_FQDN:-suru.local} may NOT resolve LAN-wide."
    log WARN "Re-run: bash deploy.sh register-dns --verbose"
    log WARN "════════════════════════════════════════════════════════"
    if [[ "${REGISTER_DNS_STRICT:-false}" =~ ^(true|yes|1)$ ]]; then
      log ERROR "REGISTER_DNS_STRICT set — failing deploy on DNS registration error"
      return 1
    fi
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: start
# ═════════════════════════════════════════════════════════════════════════════
cmd_start() {
  log STEP "Starting Tier 4 service groups${TARGET_GROUP:+ — group: ${TARGET_GROUP}}"
  load_env

  # Sanity: the tier-3 backplane must exist (or compose --remove-orphans
  # will fail). We do not create it here — it's owned by tier3-core.
  if ! docker network inspect suru-t3-core-internal >/dev/null 2>&1; then
    log ERROR "Required network suru-t3-core-internal is missing."
    log ERROR "Bring up tier3-core first: bash tier3-core/scripts/deploy.sh deploy"
    exit 1
  fi

  local -a groups=()
  resolve_groups groups
  for group in "${groups[@]}"; do
    log INFO "Starting group: ${group}"
    compose_cmd "$group" up -d --remove-orphans
    log OK "Started: ${group}"
    if [[ "$group" == "frontdoor/proxy" ]]; then
      wait_healthy "suru.t4.frontdoor.proxy" 60
    fi
  done
  log OK "Start complete"
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: stop
# ═════════════════════════════════════════════════════════════════════════════
cmd_stop() {
  log STEP "Stopping Tier 4 service groups${TARGET_GROUP:+ — group: ${TARGET_GROUP}}"
  load_env
  local -a groups=()
  resolve_groups_reversed groups
  for group in "${groups[@]}"; do
    log INFO "Stopping group: ${group}"
    compose_cmd "$group" down --remove-orphans --timeout 30
    log OK "Stopped: ${group}"
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: restart / reload
# ═════════════════════════════════════════════════════════════════════════════
cmd_restart() { cmd_stop; cmd_start; maybe_register_dns; }

cmd_reload() {
  load_env
  log STEP "Reloading nginx in the frontdoor container"
  if ! docker inspect suru.t4.frontdoor.proxy >/dev/null 2>&1; then
    log ERROR "suru.t4.frontdoor.proxy is not running — nothing to reload"; exit 1
  fi
  run docker exec suru.t4.frontdoor.proxy nginx -t
  run docker exec suru.t4.frontdoor.proxy nginx -s reload
  log OK "Reload complete"
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: deploy
# ═════════════════════════════════════════════════════════════════════════════
cmd_deploy() {
  load_env
  if [[ -n "$TARGET_GROUP" ]]; then
    log STEP "Targeted Tier 4 deploy — group: ${TARGET_GROUP}"
    cmd_start
    maybe_register_dns
    print_access_summary
    return
  fi
  log STEP "SURU Tier 4 — Full Deployment"
  check_deps
  check_docker_host_config
  cmd_certs
  cmd_start
  cmd_check || true
  maybe_register_dns
  print_access_summary
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: destroy / destroy-all
# ═════════════════════════════════════════════════════════════════════════════
cmd_destroy() {
  log STEP "Destroying Tier 4 containers and networks${TARGET_GROUP:+ — group: ${TARGET_GROUP}} (volumes preserved)"
  load_env
  if ! $SKIP_DNS && [[ -z "$TARGET_GROUP" || "$TARGET_GROUP" == "frontdoor/proxy" ]]; then
    cmd_unregister_dns || log WARN "DNS un-registration failed — continuing"
  fi
  local -a groups=()
  resolve_groups_reversed groups
  for group in "${groups[@]}"; do
    log INFO "Removing group: ${group}"
    compose_cmd "$group" down --remove-orphans --timeout 30 --volumes=false
    log OK "Removed: ${group}"
  done
  log OK "Destroy complete (data volumes retained)"
}

cmd_destroy_all() {
  log WARN "⚠️  This will DELETE all Tier 4 data volumes — irreversible!"
  if ! $DRY_RUN; then
    read -r -p "Type 'yes-destroy-all' to confirm: " confirm
    [[ "$confirm" == "yes-destroy-all" ]] || { log INFO "Aborted."; exit 0; }
  fi
  log STEP "Destroying Tier 4 containers, networks AND volumes${TARGET_GROUP:+ — group: ${TARGET_GROUP}}"
  load_env
  if ! $SKIP_DNS && [[ -z "$TARGET_GROUP" || "$TARGET_GROUP" == "frontdoor/proxy" ]]; then
    cmd_unregister_dns || log WARN "DNS un-registration failed — continuing"
  fi
  local -a groups=()
  resolve_groups_reversed groups
  for group in "${groups[@]}"; do
    log INFO "Removing group with volumes: ${group}"
    compose_cmd "$group" down --volumes --remove-orphans --timeout 30
    log OK "Removed: ${group}"
  done
  log OK "Full destruction complete"
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: status
# ═════════════════════════════════════════════════════════════════════════════
cmd_status() {
  log STEP "Container Status"
  printf "\n%-48s %-12s %-15s %s\n" "CONTAINER" "HEALTH" "STATUS" "PORTS"
  printf '%0.s─' {1..100}; echo
  local containers=(
    suru.t4.monitoring.influxdb
    suru.t4.monitoring.prometheus
    suru.t4.monitoring.grafana
    suru.t4.monitoring.watchdog
    suru.t4.frontdoor.proxy
    suru.t4.frontdoor.mdns
    suru.t4.frontdoor.content
  )
  for cname in "${containers[@]}"; do
    if docker inspect "$cname" >/dev/null 2>&1; then
      local state health ports
      state="$(docker inspect --format='{{.State.Status}}' -- "$cname")"
      health="$(docker inspect \
        --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' \
        -- "$cname")"
      ports="$(docker inspect \
        --format='{{range $p,$c := .NetworkSettings.Ports}}{{$p}}->{{(index $c 0).HostPort}} {{end}}' \
        -- "$cname" 2>/dev/null | tr -d '\n' | sed 's/ $//')"
      case "$health" in
        healthy)   health="${C_GREEN}healthy${C_RESET}" ;;
        unhealthy) health="${C_RED}unhealthy${C_RESET}" ;;
        starting)  health="${C_YELLOW}starting${C_RESET}" ;;
        *)         health="${C_CYAN}${health}${C_RESET}" ;;
      esac
      case "$state" in
        running) state="${C_GREEN}running${C_RESET}" ;;
        exited)  state="${C_RED}exited${C_RESET}" ;;
        *)       state="${C_YELLOW}${state}${C_RESET}" ;;
      esac
      printf "%-48s %-22b %-25b %s\n" "$cname" "$health" "$state" "$ports"
    else
      printf "%-48s %-12s %-15s\n" "$cname" "─" "not found"
    fi
  done
  echo
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: check
# ═════════════════════════════════════════════════════════════════════════════
cmd_check() {
  log STEP "Tier 4 Health Checks"
  load_env
  local pass=0 fail=0 warn=0

  probe() {
    local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
      printf "  ${C_GREEN}✅ PASS${C_RESET}  %s\n" "$name"; pass=$((pass + 1))
    else
      printf "  ${C_RED}❌ FAIL${C_RESET}  %s\n" "$name"
      fail=$((fail + 1))
    fi
  }
  probe_warn() {
    local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
      printf "  ${C_GREEN}✅ PASS${C_RESET}  %s\n" "$name"; pass=$((pass + 1))
    else
      printf "  ${C_YELLOW}⚠️  WARN${C_RESET}  %s\n" "$name"; warn=$((warn + 1))
    fi
  }

  echo ""
  log INFO "── Monitoring ──────────────────────────────────────────────"
  probe_warn "InfluxDB reachable" \
    "docker exec suru.t4.monitoring.influxdb curl -s http://localhost:8086/health | grep -q 'pass'"
  probe_warn "Prometheus reachable" \
    "docker exec suru.t4.monitoring.prometheus wget -qO- http://localhost:9090/prometheus/-/healthy | grep -qi 'ok\|healthy'"
  probe_warn "Grafana reachable" \
    "docker exec suru.t4.monitoring.grafana wget -qO- http://localhost:3000/api/health | grep -q 'ok'"

  echo ""
  log INFO "── Frontdoor (public LAN entry point) ──────────────────────"
  probe "Proxy container running" \
    "docker inspect -f '{{.State.Status}}' suru.t4.frontdoor.proxy | grep -q running"
  probe "/healthz reachable on localhost:${FRONTDOOR_PORT:-443}" \
    "curl -sk https://localhost:${FRONTDOOR_PORT:-443}/healthz | grep -q ok"
  probe_warn "/healthz reachable on FRONTDOOR_FQDN (LAN DNS/mDNS)" \
    "curl -sk https://${FRONTDOOR_FQDN:-suru.local}:${FRONTDOOR_PORT:-443}/healthz | grep -q ok"
  probe "mDNS sidecar running" \
    "docker inspect -f '{{.State.Status}}' suru.t4.frontdoor.mdns | grep -q running"
  probe_warn "mDNS publisher healthy (avahi-daemon alive)" \
    "docker exec suru.t4.frontdoor.mdns pgrep avahi-daemon >/dev/null"
  probe "Content sync sidecar running" \
    "docker inspect -f '{{.State.Status}}' suru.t4.frontdoor.content | grep -q running"
  probe_warn "Static landing index synced" \
    "docker exec suru.t4.frontdoor.content test -f /content/public/index.html"
  probe_warn "Landing page served via the frontdoor (HTTP 200)" \
    "curl -sk -u '${FRONTDOOR_BASIC_AUTH_USER}:${FRONTDOOR_BASIC_AUTH_PASSWORD}' -o /dev/null -w '%{http_code}' https://localhost:${FRONTDOOR_PORT:-443}/ | grep -q 200"

  echo ""
  printf "  Results: ${C_GREEN}%d passed${C_RESET}  ${C_YELLOW}%d warned${C_RESET}  ${C_RED}%d failed${C_RESET}\n\n" \
    "$pass" "$warn" "$fail"
  [[ $fail -gt 0 ]] && return 1 || return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND: logs
# ═════════════════════════════════════════════════════════════════════════════
cmd_logs() {
  load_env
  if [[ -n "$TARGET_SERVICE" ]]; then
    log INFO "Tailing logs for container: ${TARGET_SERVICE}"
    run docker logs --follow --tail 100 -- "$TARGET_SERVICE"
  elif [[ -n "$TARGET_GROUP" ]]; then
    log INFO "Tailing logs for group: ${TARGET_GROUP}"
    compose_cmd "$TARGET_GROUP" logs --follow --tail 50
  else
    log INFO "Tailing logs for all Tier 4 groups (Ctrl+C to stop)"
    local compose_files=()
    for g in "${ALL_GROUPS[@]}"; do
      [[ -f "${TIER4_DIR}/${g}/compose.yaml" ]] && compose_files+=(--file "${TIER4_DIR}/${g}/compose.yaml")
    done
    run docker compose --env-file "$ENV_FILE" "${compose_files[@]}" logs --follow --tail 50
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# HELPER: wait_healthy
# ═════════════════════════════════════════════════════════════════════════════
wait_healthy() {
  local container="$1" timeout="${2:-60}" elapsed=0 interval=5
  log INFO "Waiting for ${container} to be healthy (timeout: ${timeout}s)..."
  if $DRY_RUN; then log INFO "[DRY-RUN] Skipping wait for ${container}"; return 0; fi
  while true; do
    local status
    status="$(docker inspect \
      --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' \
      -- "$container" 2>/dev/null || echo "missing")"
    case "$status" in
      healthy|running) log OK "${container} is ${status}"; return 0 ;;
      missing)         log ERROR "Container ${container} not found"; return 1 ;;
    esac
    if [[ $elapsed -ge $timeout ]]; then
      log ERROR "Timeout waiting for ${container} (status: ${status})"
      log WARN  "Inspect logs: bash deploy.sh logs --service ${container}"
      return 1
    fi
    $VERBOSE && log INFO "  ${container} → ${status} (${elapsed}s / ${timeout}s)"
    sleep "$interval"; elapsed=$((elapsed + interval))
  done
}

# ── Access summary ─────────────────────────────────────────────────────────────
print_access_summary() {
  local fqdn="${FRONTDOOR_FQDN:-suru.local}"
  local port="${FRONTDOOR_PORT:-443}"
  local base="https://${fqdn}"
  [[ "$port" != "443" ]] && base="${base}:${port}"
  printf "\n${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
  printf "${C_BOLD} SURU Tier 4 — LAN Access (via frontdoor)${C_RESET}\n"
  printf "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
  printf "  %-38s %s\n" "OpenSearch Dashboards:"  "${base}/"
  printf "  %-38s %s\n" "Grafana:"                "${base}/grafana"
  printf "  %-38s %s\n" "Prometheus:"             "${base}/prometheus"
  printf "  %-38s %s\n" "OpenSearch REST API:"    "${base}/api/search"
  printf "  %-38s %s\n" "Logstash metrics:"       "${base}/ingestion"
  printf "  %-38s %s\n" "Beats (logstash-opnsense):" "${fqdn}:5044/tcp"
  printf "  %-38s %s\n" "Beats (logstash-pfsense):"  "${fqdn}:5045/tcp"
  printf "  %-38s %s\n" "syslog UDP (opnsense):"     "${fqdn}:5140-5142/udp"
  printf "  %-38s %s\n" "syslog UDP (pfsense):"      "${fqdn}:5143-5145/udp"
  printf "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
  printf "  Routing manifest: tier4-operations/frontdoor/proxy/config/routes.yaml\n"
  printf "  Re-render then reload: bash deploy.sh reload\n\n"
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
  parse_args "$@"
  case "$COMMAND" in
    deploy)         check_deps; cmd_deploy ;;
    start)          check_deps; cmd_start; print_access_summary ;;
    stop)           cmd_stop ;;
    restart)        check_deps; cmd_restart; print_access_summary ;;
    status)         cmd_status ;;
    check)          cmd_check ;;
    logs)           cmd_logs ;;
    destroy)        cmd_destroy ;;
    destroy-all)    cmd_destroy_all ;;
    certs)          cmd_certs ;;
    reload)         cmd_reload ;;
    check-env)      load_env; cmd_check_env ;;
    configure-host) load_env; cmd_configure_host ;;
    register-dns)   load_env; cmd_register_dns ;;
    unregister-dns) load_env; cmd_unregister_dns ;;
    -h|--help)      usage; exit 0 ;;
    *)
      log ERROR "Unknown command: '${COMMAND}'"
      printf "\nRun 'bash deploy.sh --help' for usage.\n\n"
      exit 1
      ;;
  esac
}

main "$@"
