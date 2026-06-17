#!/usr/bin/env bash
# =============================================================================
# SURU — Tier 4 Frontdoor: TLS cert generation
# =============================================================================
# Issues frontdoor.pem + frontdoor-key.pem signed by the SURU root CA at
# tier4-operations/pki/certs/root-ca.{pem,-key.pem}. Subject CN matches FRONTDOOR_FQDN
# (default: suru.local); SAN includes every name in FRONTDOOR_MDNS_ALIASES
# (default: suru.local,soc.local) plus FRONTDOOR_IP, so clients hitting any
# advertised name OR https://<IP>/ get a valid cert.
#
# Run this once per host, before bringing the frontdoor stack up. Re-run to
# rotate the cert (overwrites in place).
#
# Cert lives in tier4-operations/frontdoor/proxy/certs/ and is gitignored.
# =============================================================================
set -euo pipefail

DRY_RUN=false
VERBOSE=false
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
    -h|--help)
      cat <<'EOF'
Usage: generate-frontdoor-cert.sh [--dry-run] [--verbose]

Generates the frontdoor TLS cert signed by the SURU root CA. Re-run to rotate.

Reads from tier4-operations/.env (or tier3-core/.env as a fallback):
  FRONTDOOR_FQDN           cert CN (default: suru.local)
  FRONTDOOR_IP             SAN IPv4 entry (default: 127.0.0.1)
  FRONTDOOR_MDNS_ALIASES   comma-separated list of additional SAN DNS names
                           (default: suru.local,soc.local — matches the
                           names the mDNS sidecar advertises)
EOF
      exit 0
      ;;
  esac
done

command -v openssl >/dev/null 2>&1 || { echo "[ERROR] openssl not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="${PROXY_DIR}/certs"
REPO_ROOT="$(cd "${PROXY_DIR}/../../.." && pwd)"
CA_DIR="${REPO_ROOT}/tier4-operations/pki/certs"
# Prefer the tier4-operations env file; fall back to tier3-core/.env for
# operators who haven't migrated FRONTDOOR_* yet.
ENV_FILE_T4="${REPO_ROOT}/tier4-operations/.env"
ENV_FILE_T3="${REPO_ROOT}/tier3-core/.env"

if [[ ! -f "${CA_DIR}/root-ca.pem" || ! -f "${CA_DIR}/root-ca-key.pem" ]]; then
  echo "[ERROR] SURU root CA not found in ${CA_DIR}." >&2
  echo "        Run tier4-operations/pki/scripts/generate-certs.sh first." >&2
  exit 1
fi

# Read a KEY=value pair from the first env file that defines it; emit value
# without trailing comments / quotes / whitespace. Falls back to default arg.
read_env() {
  local key="$1" default="$2" f val
  for f in "$ENV_FILE_T4" "$ENV_FILE_T3"; do
    [[ -f "$f" ]] || continue
    val="$(grep -E "^${key}=" "$f" | tail -1 || true)"
    if [[ -n "$val" ]]; then
      val="${val#${key}=}"
      val="${val%%#*}"            # strip trailing inline comment
      val="${val%\"}"; val="${val#\"}"
      val="${val%\'}"; val="${val#\'}"
      val="$(echo "$val" | xargs)" # trim whitespace
      [[ -n "$val" ]] && { echo "$val"; return; }
    fi
  done
  echo "$default"
}

FQDN="$(read_env FRONTDOOR_FQDN suru.local)"
IP="$(read_env  FRONTDOOR_IP   127.0.0.1)"
MDNS_ALIASES="$(read_env FRONTDOOR_MDNS_ALIASES "suru.local,soc.local")"
$VERBOSE && echo "[INFO] FRONTDOOR_FQDN=${FQDN}  FRONTDOOR_IP=${IP}  FRONTDOOR_MDNS_ALIASES=${MDNS_ALIASES}"

mkdir -p "$CERT_DIR"
umask 077

# Build SAN. Collect every DNS name once (FQDN + each mDNS alias + localhost)
# and every IP once (FRONTDOOR_IP + 127.0.0.1). Order doesn't matter; dedup
# does — duplicates trip up some clients. Indexed-array dedup keeps us
# portable to bash 3.2 (macOS default).
SAN_PARTS=()
_san_has() {
  local needle="$1" hay
  for hay in "${SAN_PARTS[@]+"${SAN_PARTS[@]}"}"; do
    [[ "$hay" == "$needle" ]] && return 0
  done
  return 1
}
add_dns() { local n="$1"; [[ -z "$n" ]] && return; _san_has "DNS:${n}" || SAN_PARTS+=("DNS:${n}"); }
add_ip()  { local i="$1"; [[ -z "$i" ]] && return; _san_has "IP:${i}"  || SAN_PARTS+=("IP:${i}");  }

add_dns "$FQDN"
IFS=','
for alias in $MDNS_ALIASES; do
  alias="$(echo "$alias" | xargs)"
  add_dns "$alias"
done
unset IFS
add_dns "localhost"
add_ip  "$IP"
add_ip  "127.0.0.1"

SAN="$(IFS=', '; echo "${SAN_PARTS[*]}")"

if $DRY_RUN; then
  echo "[DRY-RUN] Would issue cert CN=${FQDN} (SAN: ${SAN}) into ${CERT_DIR}/"
  exit 0
fi

DAYS=825
SUBJ="/C=RO/O=SURU Platform/OU=SURU/CN=${FQDN}"
EXT_FILE="$(mktemp)"
SSL_ERR="$(mktemp)"
trap 'rm -f "$EXT_FILE" "$SSL_ERR"' EXIT
cat > "$EXT_FILE" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${SAN}
EOF

# Wrapper: runs an openssl command, captures stderr, shows it only on failure.
# Normal openssl progress noise (key generation dots, "Certificate request
# self-signature ok") is suppressed on success; real errors always surface.
run_openssl() {
  local desc="$1"; shift
  if ! "$@" 2>"$SSL_ERR"; then
    echo "[ERROR] ${desc} failed — openssl output:" >&2
    cat "$SSL_ERR" >&2
    return 1
  fi
  : > "$SSL_ERR"
}

# Private key
run_openssl "generate private key" \
  openssl genrsa -out "${CERT_DIR}/frontdoor-key.pem" 2048

# CSR
run_openssl "generate CSR" \
  openssl req -new -sha256 \
    -subj "${SUBJ}" \
    -key  "${CERT_DIR}/frontdoor-key.pem" \
    -out  "${CERT_DIR}/frontdoor.csr"

# Sign with the SURU root CA
run_openssl "sign cert with Root CA (${CA_DIR}/root-ca.pem)" \
  openssl x509 -req -sha256 -days "${DAYS}" \
    -CA      "${CA_DIR}/root-ca.pem" \
    -CAkey   "${CA_DIR}/root-ca-key.pem" \
    -CAcreateserial \
    -extfile "$EXT_FILE" \
    -in      "${CERT_DIR}/frontdoor.csr" \
    -out     "${CERT_DIR}/frontdoor.pem"

rm -f "${CERT_DIR}/frontdoor.csr"
chmod 600 "${CERT_DIR}/frontdoor-key.pem"
chmod 644 "${CERT_DIR}/frontdoor.pem"

# Place a copy of the public Root CA alongside the frontdoor cert so the whole
# trust bundle ships via a single `./certs:/etc/nginx/certs:ro` mount. Nesting a
# separate root-ca.pem file-mount inside that read-only directory mount fails at
# container start ("read-only file system" — Docker cannot create the nested
# mountpoint). This mirrors the tier3 pattern of keeping a Root CA copy in-tier
# (see tier4-operations/pki/README.md). Public cert only; *.pem is gitignored.
cp -- "${CA_DIR}/root-ca.pem" "${CERT_DIR}/root-ca.pem"
chmod 644 "${CERT_DIR}/root-ca.pem"

echo "[OK] Frontdoor cert issued:"
echo "       ${CERT_DIR}/frontdoor.pem      (CN=${FQDN}, SAN=${SAN}, signed by SURU root CA)"
echo "       ${CERT_DIR}/frontdoor-key.pem  (mode 0600)"
echo "       ${CERT_DIR}/root-ca.pem        (Root CA copy for in-tier trust)"
