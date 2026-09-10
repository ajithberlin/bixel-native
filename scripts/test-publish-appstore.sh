#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/publish-appstore.sh"

if rg -q 'xcrun altool --help' "$SCRIPT"; then
  echo "publish script must not probe altool with --help" >&2
  exit 1
fi

if ! rg -q 'ALTOL_NEW=1' "$SCRIPT"; then
  echo "publish script must default to current altool API-key flags" >&2
  exit 1
fi

echo "publish script uses non-blocking current altool detection"
