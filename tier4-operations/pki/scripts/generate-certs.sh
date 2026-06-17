#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
VERBOSE=false

for arg in "$@"; do
  case $arg in --dry-run) DRY_RUN=true ;; --verbose) VERBOSE=true ;; esac
done

trap 'echo "[ERROR] Certificate generation failed on line $LINENO" >&2' ERR
command -v openssl >/dev/null 2>&1 || { echo "[ERROR] openssl not found"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Root CA lives in tier4-operations/pki/certs/ (PKI authority)
ROOT_CA_DIR="${SCRIPT_DIR}/../certs"
# Tier 3 service certs live alongside the tier3-core services that use them
T3_CERT_DIR="${SCRIPT_DIR}/../../../tier3-core/certs"

SUBJ_BASE="/C=RO/O=SURU Platform/OU=SURU"
DAYS=825

if $DRY_RUN; then
  echo "[DRY-RUN] Would generate Root CA in ${ROOT_CA_DIR}"
  echo "[DRY-RUN] Would generate Tier 3 service certs in ${T3_CERT_DIR}"
  exit 0
fi

$VERBOSE && echo "[INFO] Root CA dir  : ${ROOT_CA_DIR}"
$VERBOSE && echo "[INFO] T3 cert dir  : ${T3_CERT_DIR}"

mkdir -p "${ROOT_CA_DIR}" "${T3_CERT_DIR}"
umask 077

# ── Root CA (tier4-operations/pki/certs/) ─────────────────────────────────────
openssl genrsa -out "${ROOT_CA_DIR}/root-ca-key.pem" 4096
openssl req -new -x509 -sha256 -days "${DAYS}" \
  -subj "${SUBJ_BASE}/CN=SURU Root CA" \
  -key  "${ROOT_CA_DIR}/root-ca-key.pem" \
  -out  "${ROOT_CA_DIR}/root-ca.pem"
chmod 600 "${ROOT_CA_DIR}/root-ca-key.pem"
$VERBOSE && echo "[OK] Root CA generated in ${ROOT_CA_DIR}"

# Copy Root CA public cert to tier3-core/certs/ so containers can verify chain
# without a cross-tier bind mount.
cp "${ROOT_CA_DIR}/root-ca.pem" "${T3_CERT_DIR}/root-ca.pem"
$VERBOSE && echo "[OK] root-ca.pem copied to ${T3_CERT_DIR}"

# ── Tier 3 service certs (tier3-core/certs/) ──────────────────────────────────
gen_cert() {
  local name="$1" cn="$2" san="${3:-}"
  openssl genrsa -out "${T3_CERT_DIR}/${name}-key.pem" 2048
  openssl req -new -sha256 \
    -subj "${SUBJ_BASE}/CN=${cn}" \
    -key  "${T3_CERT_DIR}/${name}-key.pem" \
    -out  "${T3_CERT_DIR}/${name}.csr"
  if [[ -n "${san}" ]]; then
    local ext_file; ext_file="$(mktemp)"
    printf 'subjectAltName=%s\n' "${san}" > "${ext_file}"
    openssl x509 -req -sha256 -days "${DAYS}" \
      -CA    "${ROOT_CA_DIR}/root-ca.pem" \
      -CAkey "${ROOT_CA_DIR}/root-ca-key.pem" \
      -CAcreateserial \
      -extfile "${ext_file}" \
      -in  "${T3_CERT_DIR}/${name}.csr" \
      -out "${T3_CERT_DIR}/${name}.pem"
    rm -f "${ext_file}"
  else
    openssl x509 -req -sha256 -days "${DAYS}" \
      -CA    "${ROOT_CA_DIR}/root-ca.pem" \
      -CAkey "${ROOT_CA_DIR}/root-ca-key.pem" \
      -CAcreateserial \
      -in  "${T3_CERT_DIR}/${name}.csr" \
      -out "${T3_CERT_DIR}/${name}.pem"
  fi
  rm -f "${T3_CERT_DIR}/${name}.csr"
  $VERBOSE && echo "[OK] Generated ${name}.pem${san:+ (SAN: ${san})}"
}

gen_cert node       "suru-t3-datalake-opensearch"
gen_cert dashboard  "suru-t3-datalake-dashboards"
# Logstash cert includes syslog.suru.local SAN so syslog-ng hostname
# verification (triggered by sni(yes)) passes when pfSense connects via
# the Tier 4 frontdoor SNI passthrough.
gen_cert logstash   "suru-t3-ingestion-logstash" \
  "DNS:syslog.suru.local,DNS:suru-t3-ingestion-logstash,DNS:localhost"
gen_cert admin      "admin"

chmod 600 "${T3_CERT_DIR}"/*-key.pem
echo "[OK] Root CA in ${ROOT_CA_DIR}"
echo "[OK] Tier 3 service certs in ${T3_CERT_DIR}"
