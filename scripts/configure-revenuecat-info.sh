#!/usr/bin/env bash
# Resolve the RevenueCat public SDK key before Xcode processes Info.plist.
# Debug builds may use .env.dev for an Xcode GUI build; release archives must
# receive the production key through xcodebuild (the publishing script does so).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST_PATH="${BIXEL_INFO_PLIST_PATH:-$ROOT/app/Bixel/Info.plist}"
DEV_ENV_FILE="${BIXEL_DEV_ENV:-$ROOT/.env.dev}"

configured_key="${REVENUECAT_API_KEY:-}"
if [[ -z "${configured_key//[[:space:]]/}" && "${CONFIGURATION:-Debug}" == "Debug" && -f "$DEV_ENV_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/scripts/load-build-env.sh"
  load_build_env "$DEV_ENV_FILE"
  configured_key="${REVENUECAT_API_KEY:-}"
fi

if [[ -z "${configured_key//[[:space:]]/}" ]]; then
  if [[ -f "$INFO_PLIST_PATH" ]]; then
    # Do not let a previous build's key leak into an unconfigured build.
    /usr/libexec/PlistBuddy -c 'Set :RevenueCatAPIKey $(REVENUECAT_API_KEY)' "$INFO_PLIST_PATH" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c 'Add :RevenueCatAPIKey string $(REVENUECAT_API_KEY)' "$INFO_PLIST_PATH"
  fi
  exit 0
fi

if [[ ! -f "$INFO_PLIST_PATH" ]]; then
  printf 'error: RevenueCat Info.plist not found at %s\n' "$INFO_PLIST_PATH" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :RevenueCatAPIKey $configured_key" "$INFO_PLIST_PATH" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :RevenueCatAPIKey string $configured_key" "$INFO_PLIST_PATH"
