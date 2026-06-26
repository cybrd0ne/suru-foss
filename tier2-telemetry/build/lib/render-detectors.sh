#!/usr/bin/env bash
# SURU Platform — Layer 2 detector render library
# Reads tier2-telemetry/opensearch/detectors/*.yml (skip *.stub.*), cross-
# references the Layer-3 field-mapping each detector declares, and renders a
# best-effort OpenSearch-Security-Analytics-shaped detector JSON document
# into tier3-core/config/opensearch/security-analytics/detectors/.
#
# Schema caveat (T0a not yet run): the OpenSearch Security Analytics
# `_plugins/_security_analytics/detectors` wire-format request body has not
# been live-verified against the running OpenSearch 3.7.0 instance (plan
# Risk R1; see also email-default.yml's identical caveat). Every rendered
# document therefore carries:
#   "_render_meta": {"schema_verified": false, "pending": "T0a"}
# This is a deliberate, visible marker — not a silent guess presented as
# confirmed. T7 (live import, a separate task) must not trust this shape
# until T0a confirms it; render-detectors.sh's job is local-file rendering
# only, never a live OpenSearch API call.
#
# Output: <tier3_out>/detectors/<slug>.json
# Called by: tier2-telemetry/build/render.sh (--scope tier3|all)

# ---------------------------------------------------------------------------
# render_detectors <t2_dir> <tier3_out> <dry_run>
# ---------------------------------------------------------------------------
render_detectors() {
  local t2_dir="$1" tier3_out="$2" dry_run="$3"

  local src_dir="${t2_dir}/opensearch/detectors"
  local out_dir="${tier3_out}/detectors"

  [[ -d "${src_dir}" ]] || { echo "[render-detectors:ERROR] Missing source dir: ${src_dir}" >&2; return 1; }

  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${out_dir}"
  fi

  local rendered_count=0
  local file slug mapping_ref mapping_file index_pattern log_type

  while IFS= read -r -d '' file; do
    slug="$(basename "${file}" .yml)"

    if [[ "${file}" == *".stub."* ]]; then
      echo "[render-detectors] Skipping stub detector: $(basename "${file}")"
      continue
    fi

    mapping_ref="$(yq -r '.field_mapping_ref // ""' "${file}")"
    if [[ -z "${mapping_ref}" ]]; then
      echo "[render-detectors:ERROR] ${slug}: missing field_mapping_ref" >&2
      return 1
    fi

    # field_mapping_ref is repo-root-relative (e.g. "tier2-telemetry/opensearch/
    # field-mappings/suru_zeek_conn.yml") — resolve relative to t2_dir's parent
    # (the repo root) regardless of t2_dir's own absolute path.
    mapping_file="$(cd "${t2_dir}/.." && pwd)/${mapping_ref}"

    [[ -f "${mapping_file}" ]] \
      || { echo "[render-detectors:ERROR] ${slug}: field_mapping_ref not found: ${mapping_ref}" >&2; return 1; }

    index_pattern="$(yq -r '.index_pattern // ""' "${file}")"
    log_type="$(yq -r '.log_type // ""' "${file}")"

    [[ -n "${index_pattern}" ]] \
      || { echo "[render-detectors:ERROR] ${slug}: missing index_pattern" >&2; return 1; }

    if [[ "${dry_run}" != "true" ]]; then
      yq -o=json '.' "${file}" \
        | jq --arg slug "${slug}" --arg mapping_ref "${mapping_ref}" '
          {
            name: .name,
            type: "detector",
            detector_type: "custom",
            status: .status,
            index_pattern: .index_pattern,
            log_type: .log_type,
            sigma_rules: .sigma_rules,
            mitre: .mitre,
            detection_filter: .detection_filter,
            schedule: .schedule,
            exclusion_predicates: .exclusion_predicates,
            actions: .actions,
            falsepositives: .falsepositives,
            verification: .verification,
            _render_meta: {
              schema_verified: false,
              pending: "T0a",
              note: "OpenSearch Security Analytics detector wire-format unverified against live 3.7.0 instance; best-effort structure only. Do not trust at import time until T0a confirms the endpoint shape.",
              source_file: $slug,
              field_mapping_ref: $mapping_ref
            }
          }
        ' > "${out_dir}/${slug}.json"
    fi

    rendered_count=$((rendered_count + 1))
    echo "[render-detectors] Rendered: ${slug} (log_type=${log_type}, index_pattern=${index_pattern})"
  done < <(find "${src_dir}" -maxdepth 1 -type f -name '*.yml' -print0 | sort -z)

  echo "[render-detectors] ${rendered_count} detector(s) rendered."
}
