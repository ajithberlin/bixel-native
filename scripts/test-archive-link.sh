#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bixel-archive-link.XXXXXX")"
trap 'rm -rf "$SETTINGS_DIR"' EXIT

# Ask Xcode for the settings it will actually use for an archive. This catches
# regressions where project.yml looks correct but the generated target drops
# the Rust archive from the Release linker invocation.
xcodebuild \
  -project "$ROOT/Bixel.xcodeproj" \
  -scheme Bixel \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -clonedSourcePackagesDirPath "$ROOT/build/DerivedData/SourcePackages" \
  -disableAutomaticPackageResolution \
  -showBuildSettings >"$SETTINGS_DIR/build-settings.txt"

ldflags="$(awk -F ' = ' '$1 ~ /OTHER_LDFLAGS/ { print $2; exit }' "$SETTINGS_DIR/build-settings.txt")"
archs="$(awk -F ' = ' '$1 ~ /ARCHS/ { print $2; exit }' "$SETTINGS_DIR/build-settings.txt")"
archive="$ROOT/generated/libbixel.a"

if [[ "$ldflags" != *"-lbixel"* ]]; then
  echo "Release archive linker flags do not link the Rust bixel archive" >&2
  echo "Resolved OTHER_LDFLAGS: ${ldflags:-<missing>}" >&2
  exit 1
fi

if [[ "$archs" != "arm64" ]]; then
  echo "Release archive requests unsupported Rust architectures: ${archs:-<missing>}" >&2
  echo "The staged Rust archive is arm64-only; configure the app archive for arm64." >&2
  exit 1
fi

echo "Release archive uses arm64 and links $archive via -lbixel"
