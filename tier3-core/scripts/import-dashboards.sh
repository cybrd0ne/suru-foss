#!/bin/sh
# SURU — Dashboard importer init container
# Imports all *.ndjson saved objects into OpenSearch Dashboards via Saved Objects API.
#
# URL strategy:
#   DASHBOARDS_INTERNAL_URL — Docker-internal hostname, used for container-to-container
#     calls inside the datalake-internal network. Always resolves correctly regardless
#     of the host OS or external DNS configuration.
#     Default: https://suru-t3-datalake-dashboards:5601
#
#   DASHBOARDS_EXTERNAL_URL — User-facing address for browsers and external tools.
#     Uses mDNS .local discovery (RFC 6762). The tier4 frontdoor bundles an
#     avahi-daemon sidecar (suru.t4.frontdoor.mdns) that advertises the names
#     in FRONTDOOR_MDNS_ALIASES (default: suru.local, soc.local) on the LAN:
#       Linux  : nss-mdns / avahi-daemon resolves .local automatically
#       macOS  : Bonjour (built-in), zero config
#       Windows: Apple Bonjour, OR use router DNS (deploy.sh register-dns)
#     Default: https://suru.local/   (Tier 4 frontdoor proxy, default landing route)
#
# This script ALWAYS uses DASHBOARDS_INTERNAL_URL — it runs inside Docker.
# OSD is configured with server.basePath=/dashboards + rewriteBasePath=true;
# all API paths below carry the /dashboards prefix accordingly.

set -eu

DASHBOARDS_URL="${DASHBOARDS_INTERNAL_URL:-https://suru-t3-datalake-dashboards:5601}"
USER="${OPENSEARCH_DASHBOARDS_USER:?OPENSEARCH_DASHBOARDS_USER must be set}"
PASS="${OPENSEARCH_DASHBOARDS_PASSWORD:?OPENSEARCH_DASHBOARDS_PASSWORD must be set}"
DASHBOARDS_DIR="/dashboards"
MAX_RETRIES=10
RETRY_DELAY=15

wait_for_dashboards() {
  echo "[INFO] Waiting for OpenSearch Dashboards at ${DASHBOARDS_URL}..."
  i=0
  until curl -sk "${DASHBOARDS_URL}/dashboards/api/status" \
        -u "${USER}:${PASS}" | grep -q '"state"'; do
    i=$((i + 1))
    if [ "$i" -ge "$MAX_RETRIES" ]; then
      echo "[ERROR] Dashboards not ready after $((MAX_RETRIES * RETRY_DELAY))s — aborting"
      exit 1
    fi
    echo "[INFO] Attempt $i/${MAX_RETRIES} — retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
  done
  echo "[OK] OpenSearch Dashboards is ready"
}

import_dashboard() {
  file="$1"
  name="$(basename "$file")"
  echo "[INFO] Importing dashboard: ${name}"
  RESPONSE=$(curl -sk -w "\n%{http_code}" \
    -X POST "${DASHBOARDS_URL}/dashboards/api/saved_objects/_import?overwrite=true" \
    -u "${USER}:${PASS}" \
    -H "osd-xsrf: true" \
    -H "kbn-xsrf: true" \
    -H "securitytenant: global" \
    -F "file=@${file};type=application/ndjson")
  HTTP_CODE=$(printf '%s' "$RESPONSE" | tail -n1)
  BODY=$(printf '%s' "$RESPONSE" | sed '$d')
  if [ "$HTTP_CODE" = "200" ]; then
    echo "[OK]  ${name} imported (${HTTP_CODE})"
  elif [ "$HTTP_CODE" = "401" ]; then
    echo "[ERROR] ${name}: HTTP 401 — check OPENSEARCH_DASHBOARDS_USER/PASSWORD" >&2
    exit 1
  else
    echo "[WARN] ${name} import returned ${HTTP_CODE}: ${BODY}"
  fi
}

wait_for_dashboards

# Remove stale index patterns superseded by 00-index-patterns.ndjson
# Uses set -- to safely iterate IDs without word-splitting on a string variable
set -- suru-access-index-pattern
for _id do
  echo "[INFO] Removing stale saved object: ${_id}"
  _http="$(curl -sk -X DELETE \
    "${DASHBOARDS_URL}/dashboards/api/saved_objects/index-pattern/${_id}" \
    -u "${USER}:${PASS}" \
    -H "osd-xsrf: true" \
    -H "kbn-xsrf: true" \
    -H "securitytenant: global" \
    -w '%{http_code}' -o /dev/null)" || true
  case "$_http" in
    200)  echo "[OK]   ${_id} deleted" ;;
    404)  echo "[INFO] ${_id} not found (already absent)" ;;
    5??)  echo "[ERROR] ${_id} returned HTTP ${_http} — aborting"; exit 1 ;;
    *)    echo "[WARN] ${_id} returned HTTP ${_http}" ;;
  esac
done

FOUND=0
for f in "${DASHBOARDS_DIR}"/*.ndjson; do
  [ -f "$f" ] || continue
  import_dashboard "$f"
  FOUND=$((FOUND + 1))
done

if [ "$FOUND" -eq 0 ]; then
  echo "[WARN] No .ndjson files found in ${DASHBOARDS_DIR} — nothing imported"
else
  echo "[OK] Dashboard import complete — ${FOUND} file(s) processed"

  # Restore index pattern field lists after import.
  # The saved_objects _import API strips the `fields` attribute on existing patterns
  # (it treats it as OSD-managed state). Pre-generated .fields-*.json files contain
  # the PUT payloads (one per pattern); this loop re-applies them so all mapped fields
  # (e.g. in_iface, rule.name) are visible in visualisations immediately.
  echo "[INFO] Restoring index pattern field lists..."
  for fields_file in "${DASHBOARDS_DIR}"/.fields-*.json; do
    [ -f "$fields_file" ] || continue
    # Derive pattern ID from filename: .fields-suru-ids-index-pattern.json -> suru-ids-index-pattern
    base=$(basename "$fields_file" .json)
    pat_id="${base#.fields-}"
    field_count=$(grep -o 'name' "$fields_file" | wc -l | tr -d ' ')
    _http=$(curl -sk -o /dev/null -w '%{http_code}' -X PUT \
      "${DASHBOARDS_URL}/dashboards/api/saved_objects/index-pattern/${pat_id}?overwrite=true" \
      -u "${USER}:${PASS}" \
      -H "osd-xsrf: true" -H "Content-Type: application/json" -H "securitytenant: global" \
      --data-binary "@${fields_file}")
    echo "[OK]   ${pat_id}: ${field_count} fields restored (HTTP ${_http})"
  done

  echo "[INFO] Access dashboards at: ${DASHBOARDS_EXTERNAL_URL:-https://suru.local/}"
fi
