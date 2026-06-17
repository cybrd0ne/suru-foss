#!/usr/bin/env bash
# =============================================================================
# SURU Platform — T2 → T1 Render Orchestrator
# Merges tier2-telemetry security intelligence with tier1-perimeter templates.
# Output: tier1-perimeter/rendered/<platform>/
#
# Usage: ./render.sh [--platform pfsense|opnsense|all] [--dry-run] [--verbose]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.."; pwd)"
T1_DIR="${REPO_ROOT}/tier1-perimeter"
T2_DIR="${REPO_ROOT}/tier2-telemetry"
LIB_DIR="${SCRIPT_DIR}/lib"

DRY_RUN=false
VERBOSE=false
PLATFORM="all"

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
    --platform) PLATFORM="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true;  shift ;;
    --verbose)  VERBOSE=true;  shift ;;
    *)          _die "Unknown argument: $1" ;;
  esac
done

PLATFORMS=()
case "${PLATFORM}" in
  pfsense)  PLATFORMS=(pfsense) ;;
  opnsense) PLATFORMS=(opnsense) ;;
  all)      PLATFORMS=(pfsense opnsense) ;;
  *)        _die "Unknown platform: ${PLATFORM}. Valid: pfsense, opnsense, all" ;;
esac

# ---------------------------------------------------------------------------
# Render loop
# Each renderer is sourced and called inside a function to contain
# any residual set -e interactions from arithmetic in library scripts.
# ---------------------------------------------------------------------------
_run_renderer() {
  local lib="$1"; shift
  # Source the library inside this function scope
  # shellcheck disable=SC1090
  source "${lib}"
  # Call the renderer function (first arg is function name, rest are args)
  local fn="$1"; shift
  "${fn}" "$@"
}

for PLAT in "${PLATFORMS[@]}"; do
  RENDERED_DIR="${T1_DIR}/rendered/${PLAT}"
  _log "Rendering for platform: ${PLAT} -> ${RENDERED_DIR}"
  if [[ "${DRY_RUN}" != "true" ]]; then
    mkdir -p "${RENDERED_DIR}/suricata"
    mkdir -p "${RENDERED_DIR}/zeek"
    mkdir -p "${RENDERED_DIR}/pfblockerng"
  fi

  _vlog "Rendering Suricata..."
  _run_renderer "${LIB_DIR}/render-suricata.sh" \
    render_suricata "${PLAT}" "${T1_DIR}" "${T2_DIR}" "${RENDERED_DIR}" "${DRY_RUN}"

  _vlog "Rendering pfBlockerNG..."
  _run_renderer "${LIB_DIR}/render-pfblockerng.sh" \
    render_pfblockerng "${PLAT}" "${T2_DIR}" "${RENDERED_DIR}" "${DRY_RUN}"

  _vlog "Rendering Zeek..."
  _run_renderer "${LIB_DIR}/render-zeek.sh" \
    render_zeek "${PLAT}" "${T1_DIR}" "${T2_DIR}" "${RENDERED_DIR}" "${DRY_RUN}"

  _log "Render complete for ${PLAT}."
done
