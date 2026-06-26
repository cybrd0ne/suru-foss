#!/usr/bin/env bash
# SURU Platform — Tier 3 (SIEM Security Analytics) render orchestrator
# Orchestrates the Layer 1-3 + STIX2 render pipeline:
#   sigma -> detectors -> correlations -> actions -> stix2
# Output lands in tier3-core/config/opensearch/security-analytics/** (and
# tier2-telemetry/threat-intel/stix2/ for the STIX2 bundle skeletons).
#
# This orchestrator makes NO live OpenSearch API calls — every sub-renderer
# writes local files only. T7 (a separate, later task) is responsible for
# the live import against a running OpenSearch cluster.
#
# Called by: tier2-telemetry/build/render.sh (--scope tier3|all)

# ---------------------------------------------------------------------------
# render_tier3 <t2_dir> <t3_dir> <lib_dir> <dry_run>
# ---------------------------------------------------------------------------
render_tier3() {
  local t2_dir="$1" t3_dir="$2" lib_dir="$3" dry_run="$4"

  local tier3_out="${t3_dir}/config/opensearch/security-analytics"
  _log "Rendering tier3 Security Analytics artifacts -> ${tier3_out}"

  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${tier3_out}/sigma"
    mkdir -p "${tier3_out}/detectors"
    mkdir -p "${tier3_out}/correlation-rules"
    mkdir -p "${tier3_out}/actions"
  fi

  _vlog "Rendering Layer 1 Sigma rules..."
  _run_renderer "${lib_dir}/render-sigma.sh" \
    render_sigma "${t2_dir}" "${tier3_out}" "${dry_run}"

  _vlog "Rendering Layer 2 detectors..."
  _run_renderer "${lib_dir}/render-detectors.sh" \
    render_detectors "${t2_dir}" "${tier3_out}" "${dry_run}"

  _vlog "Rendering Layer 2 correlation rules..."
  _run_renderer "${lib_dir}/render-correlations.sh" \
    render_correlations "${t2_dir}" "${tier3_out}" "${dry_run}"

  _vlog "Rendering Layer 2 trigger actions..."
  _run_renderer "${lib_dir}/render-actions.sh" \
    render_actions "${t2_dir}" "${tier3_out}" "${dry_run}"

  _vlog "Rendering STIX2 threat-intel bundle skeletons..."
  _run_renderer "${lib_dir}/render-stix2.sh" \
    render_stix2 "${t2_dir}" "${dry_run}"

  _vlog "Rendering pre-packaged rule selections..."
  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${tier3_out}/prepackaged-selections"
  fi
  _run_renderer "${lib_dir}/render-prepackaged.sh" \
    render_prepackaged "${dry_run}" "${VERBOSE:-false}"

  _log "Tier3 Security Analytics render complete."
}
