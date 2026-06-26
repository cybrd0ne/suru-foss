#!/usr/bin/env bash
# SURU Platform — STIX2 threat-intel render library
# Reads tier2-telemetry/threat-intel/sources.yml and produces/normalizes
# STIX2 bundle SKELETON files into tier2-telemetry/threat-intel/stix2/ — one
# bundle per `status: live` source, containing the source's own metadata
# (id/name/labels/kill_chain_phases derived from `mitre:`) but NO fetched
# indicator data.
#
# Scope boundary (deliberate, per task instructions): this renderer does
# NOT fetch the feed URLs in sources.yml — downloading from
# rules.emergingthreats.net / api.abuseipdb.com etc. is a live network call
# against a third party, not a "render local files" operation, and T3's
# remit is explicitly local-file rendering only (no live API calls of any
# kind — OpenSearch or otherwise). The actual indicator-population fetch is
# a T7/operator-run concern (tier3-core/scripts/apply-threat-intel.sh, which
# already documents its own call as unverified pending T0a). What this
# script renders is the STIX2 Bundle ENVELOPE/metadata derived from
# sources.yml — deterministic, local, and safe to run in CI.
#
# Per sources.yml's own `status` field: only `status: live` sources are
# rendered into stix2/; `status: not-live` sources are
# skipped with a logged reason, mirroring threat-intel/stix2/README.md's
# documented build-artifact/non-committed-content contract.
#
# Output: threat-intel/stix2/<name>.json (one Bundle skeleton per live source)
# Called by: tier2-telemetry/build/render.sh (--scope tier3|all)

# ---------------------------------------------------------------------------
# render_stix2 <t2_dir> <dry_run>
# ---------------------------------------------------------------------------
render_stix2() {
  local t2_dir="$1" dry_run="$2"

  local sources_file="${t2_dir}/threat-intel/sources.yml"
  local out_dir="${t2_dir}/threat-intel/stix2"

  [[ -f "${sources_file}" ]] || { echo "[render-stix2:ERROR] Missing source file: ${sources_file}" >&2; return 1; }

  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${out_dir}"
  fi

  local rendered_count=0 skipped_count=0
  local name status

  while IFS=$'\t' read -r name status; do
    [[ -n "${name}" ]] || continue

    if [[ "${status}" != "live" ]]; then
      echo "[render-stix2] Skipping not-live source: ${name}"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    local slug
    slug="$(echo "${name}" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')"

    if [[ "${dry_run}" != "true" ]]; then
      SOURCE_NAME="${name}" yq -o=json '.sources[] | select(.name == env(SOURCE_NAME))' "${sources_file}" \
        | jq --arg slug "${slug}" '
          {
            type: "bundle",
            id: ("bundle--" + $slug),
            spec_version: "2.1",
            objects: [{
              type: "indicator",
              spec_version: "2.1",
              id: ("indicator--" + $slug),
              created: now | todate,
              modified: now | todate,
              name: .name,
              description: .description,
              pattern_type: "stix",
              pattern: "[ipv4-addr:value = \"PLACEHOLDER\"]",
              valid_from: now | todate,
              labels: (.ioc_types // []),
              kill_chain_phases: [
                (.mitre // [])[] | {kill_chain_name: "mitre-attack", phase_name: .}
              ],
              external_references: [{source_name: "tier2-source", url: .source}]
            }],
            _render_meta: {
              schema_verified: false,
              pending: "T0a",
              note: "STIX2 bundle ENVELOPE only — the indicator pattern above is a PLACEHOLDER, not a fetched IOC. Actual feed-content fetch (network call to the source URL) is out of scope for T3 local-file rendering; performed by tier3-core/scripts/apply-threat-intel.sh at apply time, pending T0a live-endpoint verification.",
              origin_source: $slug
            }
          }
        ' > "${out_dir}/${slug}.json"
    fi

    rendered_count=$((rendered_count + 1))
    echo "[render-stix2] Rendered bundle skeleton: ${slug}"
  done < <(yq -r '.sources[] | [.name, .status] | @tsv' "${sources_file}")

  echo "[render-stix2] ${rendered_count} live source skeleton(s) rendered, ${skipped_count} not-live source(s) skipped."
}
