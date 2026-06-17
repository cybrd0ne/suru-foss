#!/usr/bin/env bash
# Deprecated wrapper — use deploy.sh start instead.
# Retained for backwards compatibility with any existing aliases or docs.
set -euo pipefail
exec "$(dirname "$0")/deploy.sh" start "$@"
