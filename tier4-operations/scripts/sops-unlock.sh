#!/usr/bin/env bash
set -euo pipefail

# sops-unlock.sh — Fetch age key from Keychain and export for SOPS
# Usage: source ./scripts/sops-unlock.sh

KEYCHAIN_SERVICE="sops-age-key"

command -v security >/dev/null 2>&1 || { echo "ERROR: 'security' not found (macOS only)"; exit 1; }
command -v sops >/dev/null 2>&1 || { echo "ERROR: 'sops' not found — run: brew install sops"; exit 1; }

# Retrieve the key — macOS will prompt TouchID/password if keychain is locked
AGE_KEY="$(security find-generic-password -a "${USER}" -s "${KEYCHAIN_SERVICE}" -w 2>/dev/null)"

if [[ -z "${AGE_KEY}" ]]; then
  echo "ERROR: Could not retrieve age key from Keychain. Run setup first."
  exit 1
fi

export SOPS_AGE_KEY="${AGE_KEY}"
echo "✓ SOPS age key loaded from Keychain into environment"
