#!/usr/bin/env bash
# SURU Platform — Sigma rule required-field / MITRE-tag / falsepositives validation
#
# Pure-Python YAML/required-field/MITRE-tag check documented in
# tier2-telemetry/sigma/README.md "Validation" section. Works without the
# sigma CLI installed (sigma-cli installability in CI is unconfirmed — see
# README and .github/workflows/ci.yml's separate best-effort sigma-cli step).
#
# Usage: ./validate-sigma-rules.sh [--verbose]
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/rules"
CHECKER="${SCRIPT_DIR}/.validate-sigma-rule.py"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

command -v python3 > /dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
[[ -d "${RULES_DIR}" ]] || { echo "Sigma rules dir not found: ${RULES_DIR}" >&2; exit 1; }

fail=0
count=0
while IFS= read -r -d '' f; do
  count=$((count + 1))
  if python3 "${CHECKER}" "${f}"; then
    ${VERBOSE} && echo "[validate-sigma-rules] OK: ${f}"
  else
    echo "[validate-sigma-rules] FAIL: ${f}" >&2
    fail=1
  fi
done < <(find "${RULES_DIR}" -name '*.yml' -print0)

[[ "${count}" -gt 0 ]] || { echo "No Sigma rule files found under ${RULES_DIR}" >&2; exit 1; }

if [[ "${fail}" -ne 0 ]]; then
  echo "[validate-sigma-rules] One or more rules failed validation." >&2
  exit 1
fi
echo "[validate-sigma-rules] All ${count} Sigma rule(s) passed validation."
