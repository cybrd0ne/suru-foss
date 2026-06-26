#!/usr/bin/env bash
# SURU Platform — Layer 1 Sigma render library
# Validates and copies canonical Sigma rules (tier2-telemetry/sigma/rules/**)
# into the tier3 Security Analytics staging tree, and emits a manifest of
# active (non-stub) rules consumed by render-detectors.sh.
#
# Stub convention: any file matching *.stub.* is skipped — never copied,
# never listed in the manifest. This mirrors the detector/correlation skip
# convention established by T1c (execution-persistence.stub.yml) and is
# mandatory per the tier2-telemetry SKILL safety gates.
#
# No live OpenSearch API calls — this only renders local files. T7 is the
# separate task that performs the live import.
#
# Output: <tier3_out>/sigma/<tactic>/<slug>.yml (copied, validated)
#         <tier3_out>/sigma/manifest.json        ({"rules": [...]})
# Called by: tier2-telemetry/build/render.sh (--scope tier3|all)

# ---------------------------------------------------------------------------
# render_sigma <t2_dir> <tier3_out> <dry_run>
# ---------------------------------------------------------------------------
render_sigma() {
  local t2_dir="$1" tier3_out="$2" dry_run="$3"

  local src_dir="${t2_dir}/sigma/rules"
  local out_dir="${tier3_out}/sigma"
  local manifest="${out_dir}/manifest.json"

  [[ -d "${src_dir}" ]] || { echo "[render-sigma:ERROR] Missing source dir: ${src_dir}" >&2; return 1; }

  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${out_dir}"
  fi

  local -a manifest_entries=()
  local file rel tactic slug id title status

  while IFS= read -r -d '' file; do
    rel="${file#"${src_dir}"/}"

    # Stub skip convention — mandatory, do not bypass.
    if [[ "${rel}" == *".stub."* ]]; then
      echo "[render-sigma] Skipping stub rule: ${rel}"
      continue
    fi

    # Minimal structural validation: must be parseable YAML with the
    # mandatory Sigma fields this project requires (title, id, status,
    # logsource, detection, tags). No `sigma` CLI is installed in this
    # environment, so this is a best-effort structural check, not a
    # full Sigma-spec conformance check — see self-verification notes.
    if ! python3 -c "
import sys, yaml
with open('${file}') as f:
    doc = yaml.safe_load(f)
required = ('title', 'id', 'status', 'logsource', 'detection', 'tags')
missing = [k for k in required if k not in doc]
if missing:
    print(f'missing required field(s): {missing}', file=sys.stderr)
    sys.exit(1)
"; then
      echo "[render-sigma:ERROR] ${rel} failed structural validation" >&2
      return 1
    fi

    tactic="$(dirname "${rel}")"
    slug="$(basename "${rel}" .yml)"
    id="$(yq -r '.id' "${file}")"
    title="$(yq -r '.title' "${file}")"
    status="$(yq -r '.status' "${file}")"

    if [[ "${dry_run}" != "true" ]]; then
      mkdir -p "${out_dir}/${tactic}"
      cp -- "${file}" "${out_dir}/${tactic}/${slug}.yml"
    fi

    manifest_entries+=("{\"tactic\":\"${tactic}\",\"slug\":\"${slug}\",\"id\":\"${id}\",\"title\":\"${title}\",\"status\":\"${status}\",\"path\":\"${rel}\"}")
    echo "[render-sigma] Active rule: ${rel} (${id})"
  done < <(find "${src_dir}" -type f -name '*.yml' -print0 | sort -z)

  if [[ "${dry_run}" != "true" ]]; then
    {
      printf '{"rules":['
      local first=true
      for entry in "${manifest_entries[@]+"${manifest_entries[@]}"}"; do
        ${first} || printf ','
        printf '%s' "${entry}"
        first=false
      done
      printf ']}\n'
    } > "${manifest}"
  fi

  echo "[render-sigma] ${#manifest_entries[@]} active Sigma rule(s) rendered."
}
