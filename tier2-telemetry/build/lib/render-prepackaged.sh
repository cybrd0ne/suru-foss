#!/usr/bin/env bash
# SURU Platform — render-prepackaged.sh
# Reads tier2-telemetry/opensearch/prepackaged-rules/*.yml, filters to enabled:true,
# and emits tier3-core/config/opensearch/security-analytics/prepackaged-selections/<file>.json
# Called by render-tier3.sh; never called directly.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER2_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TIER3_ROOT="$(cd "${TIER2_ROOT}/../tier3-core" && pwd)"

PREPACKAGED_DIR="${TIER2_ROOT}/opensearch/prepackaged-rules"
OUTPUT_DIR="${TIER3_ROOT}/config/opensearch/security-analytics/prepackaged-selections"

_info()  { printf '[render-prepackaged] %s\n' "$*"; }
_error() { printf '[render-prepackaged] ERROR: %s\n' "$*" >&2; }

render_prepackaged() {
  local dry_run="${1:-false}" verbose="${2:-false}"

  command -v yq  >/dev/null 2>&1 || { _error "yq required"; return 1; }
  command -v python3 >/dev/null 2>&1 || { _error "python3 required"; return 1; }

  [[ -d "${PREPACKAGED_DIR}" ]] || { _error "prepackaged-rules dir not found: ${PREPACKAGED_DIR}"; return 1; }

  if [[ "${dry_run}" == "true" ]]; then
    _info "[dry-run] would render prepackaged-rules/*.yml → ${OUTPUT_DIR}/"
  else
    mkdir -p "${OUTPUT_DIR}"
  fi

  local rendered=0
  while IFS= read -r -d '' manifest; do
    local basename
    basename="$(basename "${manifest}" .yml)"

    # skip stub files
    [[ "${basename}" == *".stub"* ]] && continue

    local category index_pattern detector_name detector_type
    category="$(yq e '.category' "${manifest}")"
    index_pattern="$(yq e '.index_pattern' "${manifest}")"
    detector_name="$(yq e '.detector_name' "${manifest}")"
    detector_type="$(yq e '.detector_type' "${manifest}")"

    # Validate field_mapping_ref files if declared per-rule
    local n_rules n_enabled
    n_rules="$(yq e '.rules | length' "${manifest}")"
    n_enabled=0

    # Collect enabled rule IDs
    local enabled_ids=()
    for i in $(seq 0 $((n_rules - 1))); do
      local enabled rule_id field_available
      enabled="$(yq e ".rules[${i}].enabled" "${manifest}")"
      rule_id="$(yq e ".rules[${i}].rule_id" "${manifest}")"
      field_available="$(yq e ".rules[${i}].field_available // true" "${manifest}")"

      [[ "${enabled}" == "true" ]] || continue
      n_enabled=$((n_enabled + 1))
      enabled_ids+=("${rule_id}")

      if [[ "${field_available}" == "false" ]] && [[ "${verbose}" == "true" ]]; then
        local note
        note="$(yq e ".rules[${i}].field_mapping_note // \"\"" "${manifest}")"
        _info "  WARN: rule ${rule_id} field_available:false — ${note:0:120}"
      fi
    done

    if [[ "${n_enabled}" -eq 0 ]]; then
      [[ "${verbose}" == "true" ]] && _info "  ${basename}: no rules enabled, skipping"
      continue
    fi

    _info "  ${basename}: ${n_enabled}/${n_rules} rules enabled → ${OUTPUT_DIR}/${basename}.json"

    if [[ "${dry_run}" != "true" ]]; then
      # Build JSON array of pre_packaged_rules
      local rules_json
      rules_json="$(python3 -c "
import json,sys
ids=sys.argv[1:]
print(json.dumps([{'id': i} for i in ids]))
" "${enabled_ids[@]}")"

      python3 -c "
import json, sys
out={
  '_render_meta':{
    'schema_verified': False,
    'pending': 'T-prepkg-verify: confirm pre_packaged_rules detector wire-shape fires correctly',
    'rendered_by': 'render-prepackaged.sh',
    'source': '$(basename "${manifest}")'
  },
  'category': '${category}',
  'detector_name': '${detector_name}',
  'detector_type': '${detector_type}',
  'index_pattern': '${index_pattern}',
  'pre_packaged_rules': json.loads(sys.argv[1]),
  'enabled': True,
  'schedule': {'period': {'interval': 5, 'unit': 'MINUTES'}},
  'triggers': []
}
print(json.dumps(out, indent=2))
" "${rules_json}" > "${OUTPUT_DIR}/${basename}.json"
    fi

    rendered=$((rendered + 1))
  done < <(find "${PREPACKAGED_DIR}" -name "*.yml" ! -name "*.stub.*" -print0 | sort -z)

  _info "Rendered ${rendered} prepackaged selection file(s)"
}

# Function is called by render-tier3.sh via _run_renderer — not called directly here.
