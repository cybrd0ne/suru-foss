#!/usr/bin/env bash
# SURU Platform — Tier 1 (perimeter) render orchestrator
# Moved verbatim out of build/render.sh (T3 dispatcher refactor) — calls the
# existing, unchanged render-{suricata,pfblockerng,zeek}.sh libs in the same
# order, with the same arguments, producing byte-identical output to the
# pre-refactor monolithic render.sh.
# Called by: tier2-telemetry/build/render.sh (--scope tier1|all)

# ---------------------------------------------------------------------------
# render_tier1 <platform> <t1_dir> <t2_dir> <lib_dir> <dry_run>
# ---------------------------------------------------------------------------
render_tier1() {
  local platform="$1" t1_dir="$2" t2_dir="$3" lib_dir="$4" dry_run="$5"

  local rendered="${t1_dir}/rendered/${platform}"
  _log "Rendering for platform: ${platform} -> ${rendered}"
  if [[ "${dry_run}" != "true" ]]; then
    mkdir -p "${rendered}/suricata"
    mkdir -p "${rendered}/zeek"
    mkdir -p "${rendered}/pfblockerng"
  fi

  _vlog "Rendering Suricata..."
  _run_renderer "${lib_dir}/render-suricata.sh" \
    render_suricata "${platform}" "${t1_dir}" "${t2_dir}" "${rendered}" "${dry_run}"

  _vlog "Rendering pfBlockerNG..."
  _run_renderer "${lib_dir}/render-pfblockerng.sh" \
    render_pfblockerng "${platform}" "${t2_dir}" "${rendered}" "${dry_run}"

  _vlog "Rendering Zeek..."
  _run_renderer "${lib_dir}/render-zeek.sh" \
    render_zeek "${platform}" "${t1_dir}" "${t2_dir}" "${rendered}" "${dry_run}"

  _log "Render complete for ${platform}."
}
