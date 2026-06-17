#!/usr/bin/env bash
# Deprecated wrapper — use update-rules.sh (Docker-based) instead.
# This script used suricata-update + systemctl, which are Linux-only and
# incompatible with pfSense (FreeBSD). update-rules.sh is the correct replacement.
set -euo pipefail
exec "$(dirname "$0")/update-rules.sh" "$@"
