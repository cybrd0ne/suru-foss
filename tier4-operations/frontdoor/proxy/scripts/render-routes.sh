#!/usr/bin/env bash
# =============================================================================
# SURU — Tier 4 Frontdoor: render routes.yaml -> nginx include files
# =============================================================================
# Reads config/routes.yaml and emits:
#   config/http/NN-<path-slug>.conf      (one server-location block per http_route)
#   config/stream/NN-<port>-<proto>.conf (one server block per stream_route)
#
# The rendered files are committed alongside routes.yaml so the running stack
# is reproducible without invoking this script. Re-run after editing
# routes.yaml; commit the resulting diff in the same PR.
#
# Dependencies: yq (mikefarah, v4+).
#
# Validate output: docker compose -f tier4-operations/frontdoor/proxy/compose.yaml config
# Reload running:  docker exec suru.t4.frontdoor.proxy nginx -s reload
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${PROXY_DIR}/config"
ROUTES_FILE="${CONFIG_DIR}/routes.yaml"
HTTP_DIR="${CONFIG_DIR}/http"
STREAM_DIR="${CONFIG_DIR}/stream"

command -v yq >/dev/null 2>&1 || {
  echo "[ERROR] yq not found in PATH. Install mikefarah/yq v4+." >&2
  exit 1
}

[[ -f "$ROUTES_FILE" ]] || {
  echo "[ERROR] routes.yaml not found at $ROUTES_FILE" >&2
  exit 1
}

# ── Clean stale renders ──────────────────────────────────────────────────────
# Keep the directories themselves; just clear .conf files we own.
shopt -s nullglob
for f in "$HTTP_DIR"/*.conf "$STREAM_DIR"/*.conf; do
  rm -f "$f"
done
shopt -u nullglob

# ── Render HTTP routes ───────────────────────────────────────────────────────
http_count="$(yq '.http_routes | length' "$ROUTES_FILE")"
for i in $(seq 0 $((http_count - 1))); do
  path="$(yq -r ".http_routes[$i].path" "$ROUTES_FILE")"
  upstream="$(yq -r ".http_routes[$i].upstream" "$ROUTES_FILE")"
  port="$(yq -r ".http_routes[$i].port" "$ROUTES_FILE")"
  scheme="$(yq -r ".http_routes[$i].scheme" "$ROUTES_FILE")"
  auth="$(yq -r ".http_routes[$i].auth" "$ROUTES_FILE")"
  comment="$(yq -r ".http_routes[$i].comment // \"\"" "$ROUTES_FILE")"
  strip_prefix="$(yq -r ".http_routes[$i].strip_prefix // \"false\"" "$ROUTES_FILE")"
  rate_limit="$(yq -r ".http_routes[$i].rate_limit // \"false\"" "$ROUTES_FILE")"

  # Slug for filename: / -> root, /a/b -> a-b, /a/ -> a (trailing slash trimmed).
  if [[ "$path" == "/" ]]; then
    slug="root"
  else
    slug="$(echo "$path" | sed 's|^/||; s|/|-|g; s|-*$||')"
  fi
  seq_num="$(printf '%02d' $((i + 10)))"
  out="${HTTP_DIR}/${seq_num}-${slug}.conf"

  auth_block=""
  if [[ "$auth" == "basic" ]]; then
    auth_block=$'\n    auth_basic           "SURU Platform";\n    auth_basic_user_file /etc/nginx/auth/htpasswd;\n    proxy_set_header Authorization "";  # strip after nginx validates — backend does not use HTTP Basic Auth\n    limit_req zone=suru_auth burst=20 nodelay;'
  fi

  rewrite_block=""
  if [[ "$strip_prefix" == "true" ]]; then
    # Strip the path prefix so upstream receives /foo not /prefix/foo.
    # location_prefix always ends in / (or is exactly / for the root),
    # so the rewrite anchors on the prefix-with-slash form.
    if [[ "$path" == "/" ]]; then
      rewrite_block="$(printf '\n    rewrite ^(/.*)$ $1 break;')"
    elif [[ "${path}" == *"/" ]]; then
      # Path already ends in /: strip it as-is (e.g. /dashboards/ → /)
      rewrite_block="$(printf '\n    rewrite ^%s(.*)$ /$1 break;' "${path}")"
    else
      # Normal non-slash path (e.g. /ingestion): location is /ingestion/
      rewrite_block="$(printf '\n    rewrite ^%s/(.*)$ /$1 break;' "${path}")"
    fi
  fi

  rate_limit_block=""
  if [[ "$rate_limit" == "true" && "$auth" != "basic" ]]; then
    rate_limit_block=$'\n    limit_req zone=suru_auth burst=20 nodelay;'
  fi

  # nginx location: proxy_pass to upstream over chosen scheme.
  # Using a variable in proxy_pass defers DNS lookup to request time (via the
  # resolver directive in nginx.conf), so the frontdoor starts even if a
  # backend container isn't running yet.
  # https upstreams are CA-verified against the SURU Root CA with SNI hostname
  # matching; http upstreams carry no proxy_ssl_* directives.
  # Var names: dots/dashes in the upstream become underscores.
  var_name="upstream_${slug//-/_}"

  ssl_block=""
  if [[ "$scheme" == "https" ]]; then
    ssl_block="$(printf '\n    proxy_ssl_trusted_certificate /etc/nginx/certs/root-ca.pem;\n    proxy_ssl_verify       on;\n    proxy_ssl_verify_depth 2;\n    proxy_ssl_name         %s;\n    proxy_ssl_server_name  on;' "${upstream}")"
  fi

  # For non-root paths that don't already end in /, emit an exact-match
  # redirect so /foo → /foo/ before the prefix location handles /foo/... .
  # This prevents a missing trailing slash from bypassing auth_basic or
  # strip-prefix rewrites.
  trailing_redirect=""
  location_prefix="${path}"
  if [[ "$path" != "/" && "${path}" != *"/" ]]; then
    trailing_redirect="location = ${path} { return 301 ${path}/; }"$'\n'
    location_prefix="${path}/"
  fi

  cat > "$out" <<EOF
# =============================================================================
# Rendered by scripts/render-routes.sh from routes.yaml — do not edit by hand.
# Route #$((i + 1)): ${comment}
# Path: ${path}  ->  ${scheme}://${upstream}:${port}
# =============================================================================
${trailing_redirect}location ${location_prefix} {${auth_block}${rate_limit_block}${rewrite_block}

    set \$${var_name} ${upstream};
    proxy_pass               ${scheme}://\$${var_name}:${port};
    proxy_http_version       1.1;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host  \$host;

    # WebSocket upgrade support (Grafana live, OSD notifications)
    # \$connection_upgrade is defined in nginx.conf via a map directive.
    proxy_set_header Upgrade           \$http_upgrade;
    proxy_set_header Connection        \$connection_upgrade;
${ssl_block}
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
}
EOF
  echo "[OK] http  ${path} -> ${scheme}://${upstream}:${port}  ($(basename "$out"))"
done

# ── Render Stream routes ─────────────────────────────────────────────────────
stream_count="$(yq '.stream_routes | length' "$ROUTES_FILE")"
for i in $(seq 0 $((stream_count - 1))); do
  listen="$(yq -r ".stream_routes[$i].listen" "$ROUTES_FILE")"
  upstream="$(yq -r ".stream_routes[$i].upstream" "$ROUTES_FILE")"
  comment="$(yq -r ".stream_routes[$i].comment // \"\"" "$ROUTES_FILE")"

  # listen is "<port>/<proto>", e.g. 5044/tcp or 5140/udp
  port="${listen%%/*}"
  proto="${listen##*/}"
  proto_lc="$(echo "$proto" | tr '[:upper:]' '[:lower:]')"

  listen_directive="listen ${port}"
  [[ "$proto_lc" == "udp" ]] && listen_directive+=" udp"
  listen_directive+=";"

  seq_num="$(printf '%02d' $((i + 10)))"
  out="${STREAM_DIR}/${seq_num}-${port}-${proto_lc}.conf"

  # Stream config: use a variable in proxy_pass so DNS resolution happens
  # at connection time, not config-load. This avoids startup failures when
  # backends are not yet running.
  cat > "$out" <<EOF
# =============================================================================
# Rendered by scripts/render-routes.sh from routes.yaml — do not edit by hand.
# Stream route #$((i + 1)): ${comment}
# Listen ${listen}  ->  ${upstream}
# =============================================================================
server {
    ${listen_directive}
    set \$stream_backend_${port}_${proto_lc} ${upstream};
    proxy_pass \$stream_backend_${port}_${proto_lc};
    proxy_timeout 300s;
    proxy_connect_timeout 5s;
}
EOF
  echo "[OK] stream ${listen} -> ${upstream}  ($(basename "$out"))"
done

echo ""
echo "Rendered ${http_count} HTTP route(s) and ${stream_count} stream route(s)."
echo "Commit routes.yaml together with the regenerated config/{http,stream}/."
