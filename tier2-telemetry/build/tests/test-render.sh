#!/usr/bin/env bash
# SURU Platform — Render pipeline integration test
# Runs render.sh --dry-run for all platforms and validates output structure.
# Usage: ./test-render.sh [--verbose]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.."; pwd)"
RENDER="${SCRIPT_DIR}/../render.sh"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

PASS=0; FAIL=0
# Use $((var+1)) instead of ((var++)) so the helpers always return 0:
# ((PASS++)) is post-increment and evaluates to the OLD value, which
# means it returns non-zero when PASS=0. That makes `cond && _pass || _fail`
# fire BOTH branches on the first PASS.
_pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
_fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

_verbose_flag=()
$VERBOSE && _verbose_flag=(--verbose)

# Test 1: render.sh exists and is executable
echo "[test-render] Test 1: render.sh executable"
[[ -x "${RENDER}" ]] && _pass "render.sh is executable" || _fail "render.sh missing or not executable"

# Test 2: dry-run completes without error for all platforms
echo "[test-render] Test 2: dry-run all platforms"
if bash "${RENDER}" --dry-run --platform all ${_verbose_flag[@]+"${_verbose_flag[@]}"} 2>&1; then
  _pass "dry-run completed"
else
  _fail "dry-run failed"
fi

# Test 3: template files exist
# Note: pfblockerng.xml.tpl was removed — render-pfblockerng.sh emits a
# PHP importer directly, no XML side file. DNSBL feed YAML is the only
# input now (covered by Test 4).
echo "[test-render] Test 3: template files present"
for f in \
  "${REPO_ROOT}/tier1-perimeter/templates/suricata/suricata.yaml.tpl" \
  "${REPO_ROOT}/tier1-perimeter/templates/zeek/local.zeek.tpl"
do
  [[ -f "${f}" ]] && _pass "template exists: $(basename "${f}")" || _fail "missing template: ${f}"
done

# Test 4: T2 data files exist
echo "[test-render] Test 4: T2 data files present"
for f in \
  "${REPO_ROOT}/tier2-telemetry/suricata/rule-selection/enable.conf" \
  "${REPO_ROOT}/tier2-telemetry/pfblockerng/categories/dnsbl-categories.yml" \
  "${REPO_ROOT}/tier2-telemetry/zeek/scripts/soho-telemetry.zeek"
do
  [[ -f "${f}" ]] && _pass "T2 data: $(basename "${f}")" || _fail "missing T2 data: ${f}"
done

# Test 5: _php_esc escaping correctness (SEC-001 regression guard)
# The pfBlockerNG importer emits PHP that runs as root on pfSense; field values
# are embedded in PHP single-quoted literals. A prior fix used ${v//\'/\\\'} which
# produces \\' (string-closing in PHP) and reopened the injection. This test pins
# the correct escaping so that regression cannot ship again.
echo "[test-render] Test 5: _php_esc PHP single-quote escaping (SEC-001)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/render-pfblockerng.sh"
# ' -> \'  (backslash + quote)
[[ "$(_php_esc "foo'bar")" == $'foo\\\'bar' ]] \
  && _pass "single-quote escaped to \\'" || _fail "single-quote NOT escaped: $(_php_esc "foo'bar")"
# \ -> \\  (doubled backslash)
[[ "$(_php_esc 'foo\bar')" == $'foo\\\\bar' ]] \
  && _pass "backslash escaped to \\\\" || _fail "backslash NOT escaped: $(_php_esc 'foo\bar')"
# trailing backslash must not dangle (would escape the closing quote in PHP)
[[ "$(_php_esc 'foo\')" == $'foo\\\\' ]] \
  && _pass "trailing backslash doubled" || _fail "trailing backslash NOT doubled: $(_php_esc 'foo\')"
# injection payload: every ' must be backslash-escaped (no bare quote can close the string)
sec001_payload="$(_php_esc "'];system('id');#")"
[[ "$sec001_payload" != *"'"* || "$sec001_payload" == *"\\'"* ]] \
  && [[ "$sec001_payload" == $'\\\'];system(\\\'id\\\');#' ]] \
  && _pass "injection payload neutralised" || _fail "injection payload NOT neutralised: $sec001_payload"

echo ""
echo "[test-render] Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
