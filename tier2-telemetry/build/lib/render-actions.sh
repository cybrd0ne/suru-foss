#!/usr/bin/env bash
# SURU Platform — Layer 2 trigger-action render library
# Reads tier2-telemetry/opensearch/actions/*.yml (skip *.stub.*) and renders
# a best-effort OpenSearch-shaped action/channel config JSON document into
# tier3-core/config/opensearch/security-analytics/actions/.
#
# Schema caveat (T0a not yet run): the live OpenSearch Notifications-plugin
# channel config API (`_plugins/_notifications/configs`) and the Security
# Analytics `trigger.actions[]` binding shape are unverified against the
# running OpenSearch 3.7.0 instance — see email-default.yml's own
# [MISSING REFERENCE] note. Every rendered document therefore carries
# "_render_meta": {"schema_verified": false, "pending": "T0a"}. No live
# OpenSearch API calls are made by this script.
#
# Secret handling: action YAMLs reference SMTP credentials only via
# ${VAR} env placeholders (per email-default.yml) — this renderer does NOT
# resolve/inline those values (no envsubst over secret-bearing fields); it
# passes the placeholder strings through verbatim so no secret material
# ever lands in a committed-adjacent build artifact. T7's live provisioner
# is responsible for resolving secrets at apply time, from the OpenSearch
# keystore, not from this rendered JSON.
#
# Output: <tier3_out>/actions/<slug>.json
# Called by: tier2-telemetry/build/render.sh (--scope tier3|all)

# ---------------------------------------------------------------------------
# render_actions <t2_dir> <tier3_out> <dry_run>
# ---------------------------------------------------------------------------
render_actions() {
  local t2_dir="$1" tier3_out="$2" dry_run="$3"

  local src_dir="${t2_dir}/opensearch/actions"
  local out_dir="${tier3_out}/actions"

  [[ -d "${src_dir}" ]] || { echo "[render-actions:ERROR] Missing source dir: ${src_dir}" >&2; return 1; }

  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${out_dir}"
  fi

  local rendered_count=0
  local file slug

  while IFS= read -r -d '' file; do
    slug="$(basename "${file}" .yml)"

    if [[ "${file}" == *".stub."* ]]; then
      echo "[render-actions] Skipping stub action: $(basename "${file}")"
      continue
    fi

    if [[ "${dry_run}" != "true" ]]; then
      yq -o=json '.' "${file}" \
        | jq --arg slug "${slug}" '
          {
            name: .name,
            type: "trigger_action",
            action_type: .action_type,
            status: .status,
            default_for: .default_for,
            recipients: .recipients,
            smtp: .smtp,
            template: .template,
            throttle: .throttle,
            target: .target,
            guardrails: .guardrails,
            _render_meta: {
              schema_verified: false,
              pending: "T0a",
              note: "OpenSearch Notifications-plugin channel config / Security Analytics trigger.actions[] binding shape unverified against live 3.7.0 instance; best-effort structure only. Secret-bearing fields (SMTP creds) are NOT resolved here — env placeholders pass through verbatim; T7 resolves from the OpenSearch keystore at apply time, never from this file.",
              source_file: $slug
            }
          }
          | with_entries(select(.value != null))
        ' > "${out_dir}/${slug}.json"
    fi

    rendered_count=$((rendered_count + 1))
    echo "[render-actions] Rendered: ${slug}"
  done < <(find "${src_dir}" -maxdepth 1 -type f -name '*.yml' -print0 | sort -z)

  echo "[render-actions] ${rendered_count} action(s) rendered."
}
