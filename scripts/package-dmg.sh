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
DRY_RUN=0

DEV_ENV_FILE="${BIXEL_DEV_ENV:-$ROOT/.env.dev}"
# shellcheck disable=SC1091
source "$ROOT/scripts/load-build-env.sh"
if [[ -f "$DEV_ENV_FILE" ]]; then
  echo "==> Loading development app config: $DEV_ENV_FILE"
  load_build_env "$DEV_ENV_FILE"
fi
REVENUECAT_API_KEY="${REVENUECAT_API_KEY:-}"

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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--version v1.0.0] [--app path/to/Bixel.app] [--output build/dist] [--build] [--dry-run]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Configuration"
  echo "  environment: $DEV_ENV_FILE"
  if [[ -n "${REVENUECAT_API_KEY//[[:space:]]/}" ]]; then
    echo "  revenuecat:  $(mask_build_secret "$REVENUECAT_API_KEY")"
  else
    echo "  revenuecat:  not configured"
  fi
  echo "Dry run — no changes made."
  exit 0
fi

# Normalize version (e.g. 1.0.0 -> TAG=v1.0.0, CLEAN=1.0.0)
CLEAN_VERSION="${VERSION#v}"
TAG="v${CLEAN_VERSION}"

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$ROOT/build/DerivedData/Build/Products/Release/Bixel.app"
fi

# project.yml is version-controlled, so the version bump below is temporary:
# back it up and restore it on exit to leave the working tree clean.
PROJECT_YML="$ROOT/project.yml"
PROJECT_YML_BACKUP=""

restore_project_yml() {
  if [[ -n "$PROJECT_YML_BACKUP" && -f "$PROJECT_YML_BACKUP" ]]; then
    cp -p "$PROJECT_YML_BACKUP" "$PROJECT_YML" 2>/dev/null || true
    rm -f "$PROJECT_YML_BACKUP" 2>/dev/null || true
  fi
}
trap restore_project_yml EXIT

if [[ "$DO_BUILD" -eq 1 ]]; then
  require_build_env_value "$REVENUECAT_API_KEY" "REVENUECAT_API_KEY in $DEV_ENV_FILE"
  PROJECT_YML_BACKUP="$(mktemp "${TMPDIR:-/tmp}/bixel-project-yml.XXXXXX")"
  cp -p "$PROJECT_YML" "$PROJECT_YML_BACKUP"

  echo "==> Updating version in project.yml to $CLEAN_VERSION"
  sed -i '' "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: \"$CLEAN_VERSION\"/" "$PROJECT_YML"

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
    REVENUECAT_API_KEY="$REVENUECAT_API_KEY" \
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
