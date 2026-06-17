#!/usr/bin/env bash
# =============================================================================
# SURU — Tier 4 Frontdoor: mDNS responder entrypoint
# =============================================================================
# Writes FRONTDOOR_MDNS_ALIASES to /etc/avahi/hosts then starts avahi-daemon.
# avahi reads the hosts file natively and publishes each entry as an A record.
# No D-Bus, no avahi-publish, no PID-file issues.
#
# Required env:
#   FRONTDOOR_IP             LAN-routable IPv4 of the Docker host
# Optional env:
#   FRONTDOOR_MDNS_ALIASES   Comma-separated list. Default: "suru.local,soc.local"
# =============================================================================
set -euo pipefail

: "${FRONTDOOR_IP:?FRONTDOOR_IP is required}"
: "${FRONTDOOR_MDNS_ALIASES:=suru.local,soc.local}"

# Refuse to advertise loopback.
if [[ "$FRONTDOOR_IP" == "127.0.0.1" || "$FRONTDOOR_IP" == "0.0.0.0" ]]; then
  echo "[mdns] ERROR: FRONTDOOR_IP=${FRONTDOOR_IP} is not LAN-routable." >&2
  echo "[mdns]        Set it to the Docker host's actual LAN IPv4 in tier4-operations/.env." >&2
  exit 1
fi

echo "[mdns] FRONTDOOR_IP=${FRONTDOOR_IP}"
echo "[mdns] FRONTDOOR_MDNS_ALIASES=${FRONTDOOR_MDNS_ALIASES}"

# ── Write /etc/avahi/hosts ────────────────────────────────────────────────────────────────
# avahi-daemon reads this file at startup and publishes each IP→name entry as
# an mDNS A record. No avahi-publish or D-Bus needed.
: > /etc/avahi/hosts
IFS=','
for alias in $FRONTDOOR_MDNS_ALIASES; do
  alias="$(echo "$alias" | xargs)"   # trim whitespace
  [[ -z "$alias" ]] && continue
  echo "[mdns] queuing: ${alias} -> ${FRONTDOOR_IP}"
  printf '%s %s\n' "${FRONTDOOR_IP}" "${alias}" >> /etc/avahi/hosts
done
unset IFS   # restore default IFS; leaving it as ',' breaks for-in word-splitting below

echo "[mdns] /etc/avahi/hosts:"
cat /etc/avahi/hosts

# ── Clean stale avahi runtime files ──────────────────────────────────────────────────
rm -f /run/avahi-daemon/pid 2>/dev/null || true

# ── Signal handling ───────────────────────────────────────────────────────────────────
shutdown() {
  echo "[mdns] shutdown — stopping avahi-daemon"
  pkill -TERM avahi-daemon 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

# ── Start avahi-daemon ─────────────────────────────────────────────────────────────────
# --no-drop-root: the container already runs as the unprivileged `avahi` user
# (USER avahi + cap_drop:ALL, SEC-038). Without this flag avahi-daemon tries to
# setgid/setuid to its configured user, which requires CAP_SETGID/CAP_SETUID —
# dropped here — so the daemon aborts ("intended to be run as root") and the
# container crash-loops. Since we are already that user, skip the drop entirely.
echo "[mdns] starting avahi-daemon (dbus-free, host-file mode)..."
avahi-daemon --no-chroot --no-rlimits --no-drop-root --daemonize

# Wait for PID file (avahi writes it after daemonizing)
for _ in $(seq 1 10); do
  [[ -f /run/avahi-daemon/pid ]] && break
  sleep 1
done

AVAHI_PID="$(cat /run/avahi-daemon/pid 2>/dev/null || true)"
if [[ -z "$AVAHI_PID" ]]; then
  echo "[mdns] ERROR: avahi-daemon did not start (no PID file)" >&2
  exit 1
fi
echo "[mdns] avahi-daemon running (pid ${AVAHI_PID})"

# Monitor avahi; exit if it dies so Docker restart policy takes over.
while kill -0 "$AVAHI_PID" 2>/dev/null; do
  sleep 5
done
echo "[mdns] avahi-daemon exited unexpectedly" >&2
exit 1
