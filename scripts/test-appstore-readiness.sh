#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/project.yml"
ABOUT="$ROOT/app/Bixel/Views/SettingsView.swift"
PROJECT_STORE="$ROOT/app/Bixel/Models/ProjectStore.swift"

if ! rg -q '^        NSHumanReadableCopyright: "[^"].*"$' "$PROJECT"; then
  echo "Mac App Store metadata must declare a non-empty copyright owner" >&2
  exit 1
fi

if ! rg -q '#if os\(macOS\)' "$PROJECT_STORE" || \
   ! rg -q 'applicationSupportDirectory' "$PROJECT_STORE"; then
  echo "Mac App Store projects must default to the app container, not an unsandboxed Documents path" >&2
  exit 1
fi

if [[ ! -f "$ROOT/site/support.html" ]]; then
  echo "The public site must provide a support page" >&2
  exit 1
fi

if ! rg -q 'https://ajithberlin\.github\.io/bixel-native/(support|privacy)\.html' \
    "$ROOT/docs/app-store/APP_STORE_LISTING.md"; then
  echo "App Store listing must use functional support and privacy URLs" >&2
  exit 1
fi

if rg -q 'GADApplicationIdentifier|ca-app-pub-' "$PROJECT" "$ROOT/app/Bixel/Info-iOS.plist"; then
  echo "The Store build must not advertise an unlinked Google Mobile Ads integration" >&2
  exit 1
fi

if ! rg -q '^        TARGETED_DEVICE_FAMILY: "2"$' "$PROJECT"; then
  echo "The iOS target must be restricted to iPad devices" >&2
  exit 1
fi

if ! rg -q 'Privacy Policy|Support' "$ABOUT"; then
  echo "The app About pane must expose legal and support links" >&2
  exit 1
fi

echo "Mac App Store readiness checks passed"
