#!/bin/sh
# =============================================================================
# SURU — Tier 4 Frontdoor: content-sync entrypoint
# =============================================================================
# Loops fetching `${CONTENT_REPO_REF}` from `${CONTENT_REPO_URL}` and resets
# the working tree to that ref every `${CONTENT_SYNC_PERIOD}`. Files land
# under /content/public/ and /content/docs/ — nginx serves them from the
# shared volume.
#
# Required env:
#   CONTENT_REPO_URL     https://github.com/<org>/<repo>.git
#   CONTENT_REPO_TOKEN   Fine-grained PAT with Contents: read on the repo
# Optional env:
#   CONTENT_REPO_REF     branch / tag / sha. Default: main
#   CONTENT_SYNC_PERIOD  poll interval. Supports 60s | 5m | 1h. Default: 60s
# =============================================================================
set -eu

: "${CONTENT_REPO_URL:?CONTENT_REPO_URL is required}"
: "${CONTENT_REPO_TOKEN:?CONTENT_REPO_TOKEN is required}"
: "${CONTENT_REPO_REF:=main}"
: "${CONTENT_SYNC_PERIOD:=60s}"

# Parse CONTENT_SYNC_PERIOD into seconds. Accept "60s", "5m", "1h", or a raw integer.
parse_period() {
  case "$1" in
    *s) printf '%s' "${1%s}" ;;
    *m) printf '%s' "$((${1%m} * 60))" ;;
    *h) printf '%s' "$((${1%h} * 3600))" ;;
    *)  printf '%s' "$1" ;;
  esac
}
SLEEP_SEC="$(parse_period "$CONTENT_SYNC_PERIOD")"
case "$SLEEP_SEC" in ''|*[!0-9]*) SLEEP_SEC=60 ;; esac

# GIT_ASKPASS handler is baked into the image at /usr/local/bin/git-askpass
# (see ../Dockerfile). It reads CONTENT_REPO_TOKEN from the environment, so the
# token stays in env only — never persisted to git config or URLs. Baking it
# (rather than writing it at runtime) lets the sidecar run non-root with a
# noexec /tmp tmpfs (SEC-038).
export GIT_ASKPASS=/usr/local/bin/git-askpass
export GIT_TERMINAL_PROMPT=0

WORK=/content

echo "[content-sync] repo=${CONTENT_REPO_URL} ref=${CONTENT_REPO_REF} period=${CONTENT_SYNC_PERIOD} (${SLEEP_SEC}s)"

# Bootstrap the working copy if missing or corrupt.
if [ ! -d "${WORK}/.git" ]; then
  echo "[content-sync] initial clone"
  # Remove anything stale (e.g. a partial previous clone) before re-cloning.
  find "${WORK}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  git clone --depth=1 --branch "${CONTENT_REPO_REF}" "${CONTENT_REPO_URL}" "${WORK}"
fi

cd "${WORK}"
# Ensure the remote URL stays exactly what the operator configured.
git remote set-url origin "${CONTENT_REPO_URL}"

shutdown() {
  echo "[content-sync] shutdown — exiting cleanly"
  exit 0
}
trap shutdown TERM INT HUP

# Main loop. Failures are logged but never fatal — the next tick retries.
while :; do
  PREV="$(git rev-parse HEAD 2>/dev/null || echo none)"
  if git fetch --depth=1 origin "${CONTENT_REPO_REF}" 2>/dev/null; then
    if git reset --hard "origin/${CONTENT_REPO_REF}" >/dev/null 2>&1; then
      NEXT="$(git rev-parse HEAD)"
      if [ "${PREV}" != "${NEXT}" ]; then
        # Trim to 7-char short SHAs for log readability.
        PREV_SHORT="$(printf '%s' "${PREV}" | cut -c1-7)"
        NEXT_SHORT="$(printf '%s' "${NEXT}" | cut -c1-7)"
        echo "[content-sync] synced ${PREV_SHORT} -> ${NEXT_SHORT}"
      fi
    else
      echo "[content-sync] WARN: reset to origin/${CONTENT_REPO_REF} failed" >&2
    fi
  else
    echo "[content-sync] WARN: fetch failed (will retry in ${SLEEP_SEC}s)" >&2
  fi
  sleep "${SLEEP_SEC}"
done
