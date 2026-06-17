#!/usr/bin/env bash
# =============================================================================
# SURU Platform — cleanup-legacy-monitoring.sh
# =============================================================================
# One-shot cleanup of legacy monitoring Docker resources. The current
# tier4-operations/monitoring/ stack uses identifiers `suru.t4.monitoring.*`
# / `suru-t4-monitoring-*`. Two historical naming schemes need cleanup:
#
#   1. `suru.t3.monitoring.*` / `suru-t3-monitoring-*`  — original layout,
#      when monitoring lived under tier3-core/.
#   2. `suru.monitoring.*` / `suru-monitoring-*`         — interim layout,
#      after the tier prefix was dropped (now reversed in favour of the
#      tier-prefixed convention).
#
# Run this ONCE on each SIEM host that was deployed with either legacy
# layout before bringing the t4-prefixed stack up.
#
# Resources removed:
#   • Containers : suru.{t3.,}monitoring.{influxdb,prometheus,grafana,watchdog}
#   • Networks   : suru-{t3-,}monitoring-internal
#   • Volumes    : suru-{t3-,}monitoring-{influxdb-data,influxdb-config,
#                  prometheus-data,grafana-data,grafana-logs}
#                  — only when --include-volumes is passed AND the typed
#                  confirmation matches. Volume deletion is irreversible.
# =============================================================================
set -euo pipefail

INCLUDE_VOLUMES=false
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: cleanup-legacy-monitoring.sh [--include-volumes] [--dry-run] [-h|--help]

Removes Docker resources from the two pre-t4 monitoring layouts:
  • `suru.t3.monitoring.*` / `suru-t3-monitoring-*`   (oldest)
  • `suru.monitoring.*`    / `suru-monitoring-*`      (interim, no tier prefix)

Options:
  --include-volumes   Also remove the data volumes (DESTRUCTIVE — confirms via
                      typed prompt). Default: skip volumes (preserve data).
  --dry-run           Print the docker commands that would run; change nothing.
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-volumes) INCLUDE_VOLUMES=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

CONTAINERS=(
  # legacy: t3 prefix
  suru.t3.monitoring.influxdb
  suru.t3.monitoring.prometheus
  suru.t3.monitoring.grafana
  suru.t3.monitoring.watchdog
  # legacy: no tier prefix
  suru.monitoring.influxdb
  suru.monitoring.prometheus
  suru.monitoring.grafana
  suru.monitoring.watchdog
)
NETWORKS=(
  suru-t3-monitoring-internal
  suru-monitoring-internal
)
VOLUMES=(
  # legacy: t3 prefix
  suru-t3-monitoring-influxdb-data
  suru-t3-monitoring-influxdb-config
  suru-t3-monitoring-prometheus-data
  suru-t3-monitoring-grafana-data
  suru-t3-monitoring-grafana-logs
  # legacy: no tier prefix
  suru-monitoring-influxdb-data
  suru-monitoring-influxdb-config
  suru-monitoring-prometheus-data
  suru-monitoring-grafana-data
  suru-monitoring-grafana-logs
)

run() {
  if $DRY_RUN; then
    echo "DRY-RUN: $*"
  else
    "$@" || true
  fi
}

command -v docker >/dev/null 2>&1 || { echo "docker not found in PATH" >&2; exit 1; }

echo "==> Stopping legacy monitoring containers"
for c in "${CONTAINERS[@]}"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    run docker stop "$c"
    run docker rm "$c"
  else
    echo "skip (absent): $c"
  fi
done

echo "==> Removing legacy monitoring networks"
for n in "${NETWORKS[@]}"; do
  if docker network inspect "$n" >/dev/null 2>&1; then
    run docker network rm "$n"
  else
    echo "skip (absent): $n"
  fi
done

if $INCLUDE_VOLUMES; then
  if ! $DRY_RUN; then
    cat <<EOF

  ⚠  About to permanently delete data volumes:
$(printf '     - %s\n' "${VOLUMES[@]}")

  This is irreversible. Type 'yes-delete-volumes' to confirm:
EOF
    read -r confirm
    if [[ "$confirm" != "yes-delete-volumes" ]]; then
      echo "Aborted — volumes retained."
      exit 0
    fi
  fi
  echo "==> Removing legacy monitoring volumes"
  for v in "${VOLUMES[@]}"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      run docker volume rm "$v"
    else
      echo "skip (absent): $v"
    fi
  done
else
  echo "==> Skipping volumes (pass --include-volumes to remove)"
  echo "    Surviving volumes (if present):"
  printf '      %s\n' "${VOLUMES[@]}"
fi

echo "==> Done. Bring the t4-prefixed stack back up with:"
echo "    docker compose -f tier4-operations/monitoring/compose.yaml up -d"
