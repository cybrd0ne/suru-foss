#!/usr/bin/env bash
# =============================================================================
# SURU Platform — Tier 2 Render Master Dispatcher
# Thin parametrized entry point over two render scopes:
#   tier1 — perimeter render (Suricata/pfBlockerNG/Zeek -> tier1-perimeter/rendered/)
#   tier3 — SIEM Security Analytics render (Layers 1-3 + STIX2 ->
#           tier3-core/config/opensearch/security-analytics/)
#
# BACKWARD COMPATIBILITY: the pre-existing `--platform pfsense|opnsense|all`
# flag (consumed by tier1-perimeter/Makefile's `render`/`deploy` targets and
# build/tests/test-render.sh) is UNCHANGED. The new `--scope tier1|tier3|all`
# flag defaults to `tier1` — today's only existing scope — so every existing
# caller (Makefile, test suite, CI) gets byte-identical behavior with zero
# changes required on their part. Opt into the new tier3 render path with
# `--scope tier3` or `--scope all`.
#
# Usage:
#   ./render.sh [--scope tier1|tier3|all] [--platform pfsense|opnsense|all] \
#               [--dry-run] [--verbose]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.."; pwd)"
T1_DIR="${REPO_ROOT}/tier1-perimeter"
T2_DIR="${REPO_ROOT}/tier2-telemetry"
T3_DIR="${REPO_ROOT}/tier3-core"
LIB_DIR="${SCRIPT_DIR}/lib"

DRY_RUN=false
VERBOSE=false
PLATFORM="all"
SCOPE="tier1"

trap '_render_cleanup' EXIT
_render_cleanup() { : ; }

_log()  { echo "[render] $*"; }
_vlog() { ${VERBOSE} && echo "[render:verbose] $*" || true; }
_warn() { echo "[render:WARN] $*" >&2; }
_die()  { echo "[render:ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# _ensure_yq: install yq to ~/.local/bin if not found in PATH
# ---------------------------------------------------------------------------
_ensure_yq() {
  if command -v yq > /dev/null 2>&1; then
    _vlog "yq found: $(command -v yq)"
    return 0
  fi

  _warn "yq not found in PATH. Attempting auto-install to ~/.local/bin/yq ..."

  local install_dir="${HOME}/.local/bin"
  mkdir -p "${install_dir}"

  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l)        arch="arm"   ;;
    *) _die "Unsupported arch for yq auto-install: ${arch}. Install manually: https://github.com/mikefarah/yq/releases" ;;
  esac

  local latest_tag
  if command -v curl > /dev/null 2>&1; then
    latest_tag="$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
  elif command -v wget > /dev/null 2>&1; then
    latest_tag="$(wget -qO- https://api.github.com/repos/mikefarah/yq/releases/latest \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
  else
    _die "curl/wget not available. Install yq manually: https://github.com/mikefarah/yq/releases"
  fi

  [[ -n "${latest_tag}" ]] || _die "Could not resolve yq release tag from GitHub API."

  local bin_name="yq_${os}_${arch}"
  local download_url="https://github.com/mikefarah/yq/releases/download/${latest_tag}/${bin_name}"
  local checksums_url="https://github.com/mikefarah/yq/releases/download/${latest_tag}/checksums"
  local tmp_bin tmp_sums
  tmp_bin="$(mktemp)"
  tmp_sums="$(mktemp)"

  _log "Downloading yq ${latest_tag} for ${os}/${arch} ..."
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL "${download_url}" -o "${tmp_bin}" \
      || _die "yq download failed. Install manually: https://github.com/mikefarah/yq/releases"
    curl -fsSL "${checksums_url}" -o "${tmp_sums}" \
      || _die "yq checksums download failed."
  else
    wget -qO "${tmp_bin}" "${download_url}" \
      || _die "yq download failed. Install manually: https://github.com/mikefarah/yq/releases"
    wget -qO "${tmp_sums}" "${checksums_url}" \
      || _die "yq checksums download failed."
  fi

  local expected_hash actual_hash
  expected_hash="$(grep "  ${bin_name}$" "${tmp_sums}" | awk '{print $1}')"
  [[ -n "${expected_hash}" ]] \
    || _die "No checksum entry for ${bin_name} in checksums file — cannot verify integrity."
  actual_hash="$(shasum -a 256 "${tmp_bin}" | awk '{print $1}')"
  [[ "${actual_hash}" == "${expected_hash}" ]] \
    || _die "yq checksum mismatch (possible supply-chain compromise). Expected: ${expected_hash}  Got: ${actual_hash}"
  _log "yq ${latest_tag} checksum verified."
  rm -f "${tmp_sums}"

  chmod +x "${tmp_bin}"
  mv "${tmp_bin}" "${install_dir}/yq"
  export PATH="${install_dir}:${PATH}"

  command -v yq > /dev/null 2>&1 \
    || _die "yq install appeared to succeed but binary not executable. Check ${install_dir}/yq"

  _log "yq installed: ${install_dir}/yq"
}

# ---------------------------------------------------------------------------
# Hard dependency check
# ---------------------------------------------------------------------------
for _cmd in envsubst sed awk; do
  command -v "${_cmd}" > /dev/null 2>&1 \
    || _die "Required command not found: ${_cmd}"
done
unset _cmd

_ensure_yq

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)    SCOPE="$2";    shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true;  shift ;;
    --verbose)  VERBOSE=true;  shift ;;
    *)          _die "Unknown argument: $1" ;;
  esac
done

case "${SCOPE}" in
  tier1|tier3|all) ;;
  *) _die "Unknown scope: ${SCOPE}. Valid: tier1, tier3, all" ;;
esac

PLATFORMS=()
case "${PLATFORM}" in
  pfsense)  PLATFORMS=(pfsense) ;;
  opnsense) PLATFORMS=(opnsense) ;;
  all)      PLATFORMS=(pfsense opnsense) ;;
  *)        _die "Unknown platform: ${PLATFORM}. Valid: pfsense, opnsense, all" ;;
esac

# ---------------------------------------------------------------------------
# _run_renderer: source a render library inside this function scope and
# invoke the named function. Containing the source here (rather than at
# top level) isolates any residual `set -e` interactions from arithmetic in
# library scripts, matching the pre-refactor behavior exactly.
# ---------------------------------------------------------------------------
_run_renderer() {
  local lib="$1"; shift
  # shellcheck disable=SC1090
  source "${lib}"
  local fn="$1"; shift
  "${fn}" "$@"
}

# ---------------------------------------------------------------------------
# Tier 1 — perimeter render (existing behavior, unchanged output)
# ---------------------------------------------------------------------------
if [[ "${SCOPE}" == "tier1" || "${SCOPE}" == "all" ]]; then
  for PLAT in "${PLATFORMS[@]}"; do
    _run_renderer "${LIB_DIR}/render-tier1.sh" \
      render_tier1 "${PLAT}" "${T1_DIR}" "${T2_DIR}" "${LIB_DIR}" "${DRY_RUN}"
  done
fi

# ---------------------------------------------------------------------------
# Tier 3 — SIEM Security Analytics render (new)
# ---------------------------------------------------------------------------
if [[ "${SCOPE}" == "tier3" || "${SCOPE}" == "all" ]]; then
  _run_renderer "${LIB_DIR}/render-tier3.sh" \
    render_tier3 "${T2_DIR}" "${T3_DIR}" "${LIB_DIR}" "${DRY_RUN}"
fi
