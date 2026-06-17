#!/bin/sh
# SURU — Logstash plugin bootstrap entrypoint
# Installs logstash-output-opensearch at container startup before Logstash launches.
# Idempotent: skips install if the plugin is already present.
#
# Plugin: logstash-output-opensearch (latest from RubyGems)
#   Latest: 2.1.1 (March 2026) — supports OpenSearch 1.x / 2.x / 3.x
#   No --version flag: logstash-plugin treats this as an alias; specifying
#   a version causes "Installs of an alias doesn't require version specification".
#
# IMPORTANT — do NOT pipe logstash-plugin list directly to grep:
#   logstash-plugin list is a JRuby process. When grep closes its stdin on first
#   match, the pipe breaks (EPIPE). JRuby escalates EPIPE to SystemExit, which
#   with set -e causes the entrypoint to abort — even if the plugin IS installed.
#   Fix: write list output to a temp file first, then grep the file.
#
#   Ref: https://rubygems.org/gems/logstash-output-opensearch/versions
#   Ref: https://github.com/opensearch-project/logstash-output-opensearch

set -e

PLUGIN="logstash-output-opensearch"
PLUGIN_LIST_TMP="$(mktemp)"
trap 'rm -f "${PLUGIN_LIST_TMP}"' EXIT

# Write plugin list to temp file — avoids EPIPE/SystemExit from JRuby pipe breakage
/usr/share/logstash/bin/logstash-plugin list > "${PLUGIN_LIST_TMP}" 2>/dev/null || true

if grep -q "^${PLUGIN}$" "${PLUGIN_LIST_TMP}"; then
  echo "[suru-entrypoint] Plugin ${PLUGIN} already installed — skipping"
else
  echo "[suru-entrypoint] Installing ${PLUGIN} (latest)..."
  /usr/share/logstash/bin/logstash-plugin install "${PLUGIN}"
  echo "[suru-entrypoint] Plugin installed successfully"
fi

# --- GeoIP pipeline activation -------------------------------------------------
# The `geoip` pipeline (pipelines.yml) loads /tmp/geoip-pipeline/35-geoip.conf.
# The Logstash geoip filter is FATAL at startup if its database file is missing,
# so we choose the variant by DB presence:
#   DB present -> 35-geoip.conf             (geoip + ASN enrichment)
#   DB absent  -> 35-geoip-passthrough.conf (no geoip; events still indexed)
# Only the pfsense profile ships these source files; the guard keeps this shared
# entrypoint a no-op for the opnsense profile.
GEOIP_SRC_DIR="/usr/share/logstash/pipeline"
GEOIP_PIPE_DIR="/tmp/geoip-pipeline"
GEOIP_CITY_DB="${GEOIP_CITY_DB:-/usr/share/logstash/geoip/GeoLite2-City.mmdb}"
if [ -f "${GEOIP_SRC_DIR}/35-geoip.conf" ] && [ -f "${GEOIP_SRC_DIR}/35-geoip-passthrough.conf" ]; then
  mkdir -p "${GEOIP_PIPE_DIR}"
  if [ -f "${GEOIP_CITY_DB}" ]; then
    echo "[suru-entrypoint] GeoIP DB present (${GEOIP_CITY_DB}) — enabling geoip enrichment"
    cp "${GEOIP_SRC_DIR}/35-geoip.conf" "${GEOIP_PIPE_DIR}/35-geoip.conf"
  else
    echo "[suru-entrypoint] No GeoIP DB at ${GEOIP_CITY_DB} — geoip pipeline runs in passthrough mode"
    cp "${GEOIP_SRC_DIR}/35-geoip-passthrough.conf" "${GEOIP_PIPE_DIR}/35-geoip.conf"
  fi
fi

echo "[suru-entrypoint] Starting Logstash..."
exec /usr/local/bin/docker-entrypoint "$@"
