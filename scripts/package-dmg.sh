#!/usr/bin/env bash
#
# Package Bixel.app into a compressed macOS DMG (.dmg) file with an
# Applications symlink for drag-and-drop installation.
#
# Usage:
#   scripts/package-dmg.sh [--version v1.0.0] [--app path/to/Bixel.app] [--output build/dist] [--build]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="v1.0.0"
APP_PATH=""
OUTPUT_DIR="$ROOT/build/dist"
DO_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      VERSION="$2"
      shift 2
      ;;
    --app|-a)
      APP_PATH="$2"
      shift 2
      ;;
    --output|-o)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --build|-b)
      DO_BUILD=1
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--version v1.0.0] [--app path/to/Bixel.app] [--output build/dist] [--build]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Normalize version (e.g. 1.0.0 -> TAG=v1.0.0, CLEAN=1.0.0)
CLEAN_VERSION="${VERSION#v}"
TAG="v${CLEAN_VERSION}"

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$ROOT/build/DerivedData/Build/Products/Release/Bixel.app"
fi

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "==> Updating version in project.yml to $CLEAN_VERSION"
  sed -i '' "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: \"$CLEAN_VERSION\"/" "$ROOT/project.yml"

  echo "==> Generating Xcode project"
  (cd "$ROOT" && xcodegen generate)

  echo "==> Building Rust static library"
  (cd "$ROOT" && ./scripts/build-rust.sh)

  echo "==> Building Release Bixel.app via xcodebuild"
  (cd "$ROOT" && xcodebuild -project Bixel.xcodeproj \
    -scheme Bixel \
    -configuration Release \
    -destination 'platform=macOS' \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build)
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: Application bundle not found at '$APP_PATH'." >&2
  echo "Run with --build or build the Release scheme first:" >&2
  echo "  $0 --build --version $TAG" >&2
  exit 1
fi

echo "==> Ensuring ad-hoc code signature on $APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

STAGING_DIR="$ROOT/build/dmg_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$OUTPUT_DIR"

echo "==> Staging DMG contents"
cp -R "$APP_PATH" "$STAGING_DIR/Bixel.app"
ln -s /Applications "$STAGING_DIR/Applications"

DMG_NAME="Bixel-${TAG}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

echo "==> Creating DMG: $DMG_PATH"
hdiutil create -volname "Bixel Studio" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

echo "==> Generating SHA-256 checksum"
(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256")

rm -rf "$STAGING_DIR"

echo "==> Done!"
echo "    DMG:      $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "    Checksum: $OUTPUT_DIR/${DMG_NAME}.sha256"
cat "$OUTPUT_DIR/${DMG_NAME}.sha256"
