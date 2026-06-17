#!/bin/sh
# =============================================================================
# SURU — Tier 4 Frontdoor: nginx container entrypoint
# =============================================================================
# Materialises /etc/nginx/auth/htpasswd from FRONTDOOR_BASIC_AUTH_USER /
# FRONTDOOR_BASIC_AUTH_PASSWORD before invoking nginx. The htpasswd file is
# kept inside the container only — never written to the host bind-mount, so
# it never gets committed.
#
# Tests:
#   - aborts if either env var is unset
#   - aborts if frontdoor cert/key are missing (operator must run
#     scripts/generate-frontdoor-cert.sh first)
#   - runs `nginx -t` to validate the rendered config before exec
# =============================================================================
set -eu

require_env() {
  eval "val=\${$1:-}"
  if [ -z "$val" ]; then
    echo "[ERROR] entrypoint: $1 is unset — set it in tier4-operations/.env" >&2
    exit 1
  fi
}

require_env FRONTDOOR_BASIC_AUTH_USER
require_env FRONTDOOR_BASIC_AUTH_PASSWORD

for f in /etc/nginx/certs/frontdoor.pem /etc/nginx/certs/frontdoor-key.pem; do
  if [ ! -s "$f" ]; then
    echo "[ERROR] entrypoint: $f missing — run" >&2
    echo "       tier4-operations/frontdoor/proxy/scripts/generate-frontdoor-cert.sh" >&2
    exit 1
  fi
done

mkdir -p /etc/nginx/auth
# Apache htpasswd bcrypt format. The `-B` flag is supported by Alpine's
# apache2-utils; if not available we fall back to the openssl APR1 variant.
if command -v htpasswd >/dev/null 2>&1; then
  htpasswd -b -B -c /etc/nginx/auth/htpasswd \
    "$FRONTDOOR_BASIC_AUTH_USER" "$FRONTDOOR_BASIC_AUTH_PASSWORD" >/dev/null
else
  HASH="$(openssl passwd -apr1 "$FRONTDOOR_BASIC_AUTH_PASSWORD")"
  printf '%s:%s\n' "$FRONTDOOR_BASIC_AUTH_USER" "$HASH" > /etc/nginx/auth/htpasswd
fi
chmod 0644 /etc/nginx/auth/htpasswd

# Generate SNI ingestion map from FRONTDOOR_INGESTION_FQDNS.
# Each comma-separated hostname maps to the loopback passthrough server (9443)
# which forwards raw TLS to the appropriate backend without PROXY protocol.
# This file is included by the nginx stream map block in nginx.conf.
# Always write the file even if empty so the include directive never fails.
sni_map_file="/run/nginx/sni-ingestion-map.conf"
mkdir -p "$(dirname "$sni_map_file")"
: > "$sni_map_file"
if [ -n "${FRONTDOOR_INGESTION_FQDNS:-}" ]; then
    printf '%s\n' "$FRONTDOOR_INGESTION_FQDNS" | tr ',' '\n' | while IFS= read -r _fqdn; do
        _fqdn="${_fqdn# }"; _fqdn="${_fqdn% }"   # trim whitespace
        [ -z "$_fqdn" ] && continue
        printf '    %s  127.0.0.1:9443;\n' "$_fqdn"
    done >> "$sni_map_file"
    echo "[entrypoint] SNI ingestion map: $(wc -l < "$sni_map_file" | tr -d ' ') entries"
else
    echo "[entrypoint] FRONTDOOR_INGESTION_FQDNS not set — SNI ingestion map is empty"
fi

# Wait for critical stream backends to appear in Docker DNS before starting.
# This is the cross-project equivalent of depends_on: condition: service_started.
# nginx now uses variable proxy_pass (runtime resolver) so it will start even
# if a backend is absent — but we log a warning so operators know the state.
wait_dns() {
  _host="$1" _max="${2:-30}" _i=0
  while [ "$_i" -lt "$_max" ]; do
    nslookup "$_host" 127.0.0.11 >/dev/null 2>&1 && return 0
    _i=$(( _i + 1 ))
    echo "[entrypoint] waiting for DNS: ${_host} (attempt ${_i}/${_max})"
    sleep 2
  done
  echo "[entrypoint] WARNING: ${_host} not yet in DNS after $(( _max * 2 ))s — nginx will resolve per-connection"
}

echo "[entrypoint] Checking upstream DNS readiness..."
wait_dns suru-t3-ingestion-logstash-pfsense 15
wait_dns suru-t3-datalake-opensearch 15
echo "[entrypoint] DNS check complete"

# Validate the rendered config before handing off to nginx -g 'daemon off'.
nginx -t

exec nginx -g 'daemon off;'
