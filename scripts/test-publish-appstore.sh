#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/publish-appstore.sh"
PROJECT="$ROOT/project.yml"
ENTITLEMENTS="$ROOT/app/Bixel/Bixel-AppStore.entitlements"
REVIEW_NOTES="$ROOT/docs/app-store/APP_STORE_LISTING.md"

if rg -q 'xcrun altool --help' "$SCRIPT"; then
  echo "publish script must not probe altool with --help" >&2
  exit 1
fi

if ! rg -q 'ALTOL_NEW=1' "$SCRIPT"; then
  echo "publish script must default to current altool API-key flags" >&2
  exit 1
fi

if rg -q 'SIGN_ARGS\+=\("CODE_SIGN_IDENTITY=Apple Distribution"\)' "$SCRIPT"; then
  echo "automatic signing must not force Apple Distribution on package targets" >&2
  exit 1
fi

if rg -q '^        CODE_SIGN_IDENTITY: "-"$|^        CODE_SIGNING_REQUIRED: NO$' "$PROJECT"; then
  echo "Release must not inherit ad-hoc signing settings" >&2
  exit 1
fi

if ! rg -q '^          CODE_SIGNING_REQUIRED: YES$' "$PROJECT"; then
  echo "Release signing must be required" >&2
  exit 1
fi

if ! rg -q '"CODE_SIGNING_REQUIRED=YES"' "$SCRIPT"; then
  echo "publish archive must require code signing" >&2
  exit 1
fi

if ! rg -q 'Signature=adhoc' "$SCRIPT"; then
  echo "publish script must reject ad-hoc archives" >&2
  exit 1
fi

if ! rg -q '^        LSApplicationCategoryType: public\.app-category\.graphics-design$' "$PROJECT"; then
  echo "Mac App Store target must declare an application category" >&2
  exit 1
fi

if ! rg -q -U '<key>com\.apple\.security\.network\.server</key>\s*<true/>' "$ENTITLEMENTS"; then
  echo "App Store entitlements must allow the Mac's user-enabled remote listener" >&2
  exit 1
fi

if ! rg -q 'NWListener|Enable Remote Access|_bixel-remote\._tcp' "$REVIEW_NOTES"; then
  echo "App Review notes must explain the user-enabled incoming remote connection" >&2
  exit 1
fi

echo "publish script uses non-blocking current altool detection"
