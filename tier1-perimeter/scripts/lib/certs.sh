#!/usr/bin/env bash
# =============================================================================
# SURU Tier 1 — lib/certs.sh
# mTLS client certificate generation signed by the SURU Root CA.
# The Root CA is managed exclusively by tier4-operations/pki/scripts/generate-certs.sh
# and lives at tier4-operations/pki/certs/root-ca.pem.
# =============================================================================

# certs_check_ca
# Validates that the SURU Root CA exists and is not near expiry.
certs_check_ca() {
  local ca_cert="${REPO_ROOT}/tier4-operations/pki/certs/root-ca.pem"
  local ca_key="${REPO_ROOT}/tier4-operations/pki/certs/root-ca-key.pem"

  [[ -f "$ca_cert" ]] || log_die "SURU Root CA not found: ${ca_cert}\nRun: tier4-operations/pki/scripts/generate-certs.sh"
  [[ -f "$ca_key"  ]] || log_die "SURU Root CA key not found: ${ca_key}\nRun: tier4-operations/pki/scripts/generate-certs.sh"

  # Warn if CA expires within 60 days
  local expiry expiry_epoch now_epoch days_left
  expiry=$(openssl x509 -in "$ca_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
  expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || \
                 date -j -f "%b %d %T %Y %Z" "${expiry}" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
  if [[ $days_left -lt 60 ]]; then
    log_warn "SURU Root CA expires in ${days_left} days (${expiry}) — consider renewal"
  else
    log_debug "Root CA valid for ${days_left} days"
  fi

  log_info "SURU Root CA: OK (${ca_cert})"
}

# certs_generate_client CERT_NAME
# Generates a client cert+key pair in tier1-perimeter/certs/, signed by the
# SURU Root CA. Idempotent: skips if a valid cert already exists.
#
# Args:
#   CERT_NAME  — base name without extension, e.g. tier1-pfsense-syslogng
certs_generate_client() {
  local name="$1"
  local cert_dir="${TIER1_DIR}/certs"
  local ca_cert="${REPO_ROOT}/tier4-operations/pki/certs/root-ca.pem"
  local ca_key="${REPO_ROOT}/tier4-operations/pki/certs/root-ca-key.pem"
  local ca_srl="${REPO_ROOT}/tier4-operations/pki/certs/root-ca.srl"
  local client_key="${cert_dir}/${name}-key.pem"
  local client_csr="${cert_dir}/${name}.csr"
  local client_cert="${cert_dir}/${name}.pem"
  local subj="/C=RO/O=SURU Platform/OU=Tier1/CN=suru-${name}"

  certs_check_ca

  # Idempotency check — skip if cert exists and verifies against CA
  if [[ -f "$client_cert" ]]; then
    if openssl verify -CAfile "$ca_cert" "$client_cert" >/dev/null 2>&1; then
      log_info "Client cert already valid, skipping generation: ${client_cert}"
      return 0
    else
      log_warn "Existing cert ${client_cert} failed CA verification — regenerating"
    fi
  fi

  run mkdir -p "$cert_dir"

  log_info "Generating EC P-256 key: ${client_key}"
  run openssl ecparam -name prime256v1 -genkey -noout -out "$client_key"

  log_info "Generating CSR: ${client_csr}"
  run openssl req -new -sha256 \
      -subj  "$subj" \
      -key   "$client_key" \
      -out   "$client_csr"

  log_info "Signing with SURU Root CA ..."
  if [[ -f "$ca_srl" ]]; then
    run openssl x509 -req -sha256 -days 365 \
        -CA "$ca_cert" -CAkey "$ca_key" -CAserial "$ca_srl" \
        -in "$client_csr" -out "$client_cert"
  else
    run openssl x509 -req -sha256 -days 365 \
        -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -in "$client_csr" -out "$client_cert"
  fi

  run chmod 600 "$client_key"
  # CSR is single-use once signed — clean it up explicitly rather than via a
  # `trap ... RETURN` (a prior version of this function used one: it fires on
  # every SUBSEQUENT function return in the whole script, not just this one,
  # so once this function's own early-return path fired it once, it kept
  # firing on unrelated later function returns where client_csr was long out
  # of scope, throwing "client_csr: unbound variable" under set -u).
  run rm -f "$client_csr"
  log_info "Client cert generated: ${client_cert}"
}
