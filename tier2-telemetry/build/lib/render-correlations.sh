#!/usr/bin/env bash
# SURU Platform — Layer 2 correlation-rule render library
# Reads tier2-telemetry/opensearch/correlations/*.yml (skip *.stub.*) and
# renders a best-effort OpenSearch-Security-Analytics-shaped correlation-rule
# JSON document into tier3-core/config/opensearch/security-analytics/
# correlation-rules/.
#
# Schema caveat (T0a not yet run): the live Security Analytics
# correlation-rule wire format (join semantics, finding-vs-raw-event join
# operators) is unverified against the running OpenSearch 3.7.0 instance —
# see pfblockerng-suricata-zeek-c2-chain.yml's own verification block, which
# explicitly defers this to T7/T0a. Every rendered document therefore
# carries "_render_meta": {"schema_verified": false, "pending": "T0a"}.
# No live OpenSearch API calls are made by this script.
#
# Output: <tier3_out>/correlation-rules/<slug>.json
# Called by: tier2-telemetry/build/render.sh (--scope tier3|all)

# ---------------------------------------------------------------------------
# render_correlations <t2_dir> <tier3_out> <dry_run>
# ---------------------------------------------------------------------------
render_correlations() {
  local t2_dir="$1" tier3_out="$2" dry_run="$3"

  local src_dir="${t2_dir}/opensearch/correlations"
  local out_dir="${tier3_out}/correlation-rules"

  [[ -d "${src_dir}" ]] || { echo "[render-correlations:ERROR] Missing source dir: ${src_dir}" >&2; return 1; }

  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${out_dir}"
  fi

  local rendered_count=0
  local file slug

  while IFS= read -r -d '' file; do
    slug="$(basename "${file}" .yml)"

    if [[ "${file}" == *".stub."* ]]; then
      echo "[render-correlations] Skipping stub correlation rule: $(basename "${file}")"
      continue
    fi

    if [[ "${dry_run}" != "true" ]]; then
      yq -o=json '.' "${file}" \
        | jq --arg slug "${slug}" '
          {
            name: .name,
            type: "correlation_rule",
            status: .status,
            join: .join,
            legs: .legs,
            mitre: .mitre,
            schedule: .schedule,
            actions: .actions,
            falsepositives: .falsepositives,
            verification: .verification,
            _render_meta: {
              schema_verified: false,
              pending: "T0a",
              note: "OpenSearch Security Analytics correlation-rule wire-format unverified against live 3.7.0 instance; best-effort structure only. Do not trust at import time until T0a confirms the endpoint shape.",
              source_file: $slug
            }
          }
        ' > "${out_dir}/${slug}.json"
    fi

    rendered_count=$((rendered_count + 1))
    echo "[render-correlations] Rendered: ${slug}"
  done < <(find "${src_dir}" -maxdepth 1 -type f -name '*.yml' -print0 | sort -z)

  echo "[render-correlations] ${rendered_count} correlation rule(s) rendered."
}
