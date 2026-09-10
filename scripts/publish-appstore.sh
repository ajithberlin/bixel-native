#!/usr/bin/env bash
#
# Build Bixel Studio for the Mac App Store, export a signed .pkg, optionally
# validate + upload it to App Store Connect, and optionally push the release tag.
#
# Configuration is read from `.env.deploy` (see `.env.deploy.example`). Any value
# can also be passed as an environment variable or overridden with a CLI flag.
#
# Usage:
#   scripts/publish-appstore.sh [options]
#
# Options:
#   --version <x.y.z>     Marketing version (overrides APPSTORE_VERSION)
#   --build-number <n>    Build number (overrides APPSTORE_BUILD_NUMBER)
#   --skip-upload         Build + validate only; do not upload
#   --skip-build          Reuse the last archive/pkg; only validate/upload
#   --archive-only        Stop after producing the .xcarchive
#   --git-push            Create and push the vX.Y.Z tag after a successful upload
#   --dry-run             Print the resolved configuration and commands, do nothing
#   -h, --help            Show this help
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load .env.deploy
# ---------------------------------------------------------------------------
ENV_FILE="${BIXEL_DEPLOY_ENV:-$ROOT/.env.deploy}"
if [[ -f "$ENV_FILE" ]]; then
  log "Loading deployment config: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  warn "No $ENV_FILE found; relying on environment + defaults."
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
APPSTORE_BUNDLE_ID="${APPSTORE_BUNDLE_ID:-com.bixel.studio}"
APPSTORE_VERSION="${APPSTORE_VERSION:-1.0.0}"
APPSTORE_BUILD_NUMBER="${APPSTORE_BUILD_NUMBER:-}"
APPSTORE_SIGNING_STYLE="${APPSTORE_SIGNING_STYLE:-manual}"
APPSTORE_CODE_SIGN_IDENTITY="${APPSTORE_CODE_SIGN_IDENTITY:-Apple Distribution}"
APPSTORE_PROVISIONING_PROFILE="${APPSTORE_PROVISIONING_PROFILE:-}"
APPSTORE_ENTITLEMENTS="${APPSTORE_ENTITLEMENTS:-app/Bixel/Bixel-AppStore.entitlements}"
APPSTORE_API_KEY_ID="${APPSTORE_API_KEY_ID:-}"
APPSTORE_API_ISSUER_ID="${APPSTORE_API_ISSUER_ID:-}"
APPSTORE_API_KEY_PATH="${APPSTORE_API_KEY_PATH:-}"
APPSTORE_APPLE_ID="${APPSTORE_APPLE_ID:-}"
APPSTORE_APP_SPECIFIC_PASSWORD="${APPSTORE_APP_SPECIFIC_PASSWORD:-}"
APPSTORE_SKIP_UPLOAD="${APPSTORE_SKIP_UPLOAD:-0}"
APPSTORE_GIT_PUSH="${APPSTORE_GIT_PUSH:-0}"
APPSTORE_GIT_REMOTE="${APPSTORE_GIT_REMOTE:-origin}"

SKIP_UPLOAD=0
SKIP_BUILD=0
ARCHIVE_ONLY=0
DRY_RUN=0

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)      APPSTORE_VERSION="$2"; shift 2 ;;
    --build-number|-b) APPSTORE_BUILD_NUMBER="$2"; shift 2 ;;
    --skip-upload)     SKIP_UPLOAD=1; shift ;;
    --skip-build)      SKIP_BUILD=1; shift ;;
    --archive-only)    ARCHIVE_ONLY=1; shift ;;
    --git-push)        APPSTORE_GIT_PUSH=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)
      cat <<'HELP'
Usage: scripts/publish-appstore.sh [options]

Build Bixel Studio for the Mac App Store, export a signed .pkg, optionally
validate + upload it to App Store Connect, and optionally push the release tag.

Configuration is read from .env.deploy (see .env.deploy.example). Any value can
also be passed as an environment variable or overridden with a CLI flag.

Options:
  --version <x.y.z>     Marketing version (overrides APPSTORE_VERSION)
  --build-number <n>    Build number (overrides APPSTORE_BUILD_NUMBER)
  --skip-upload         Build + validate only; do not upload
  --skip-build          Reuse the last archive/pkg; only validate/upload
  --archive-only        Stop after producing the .xcarchive
  --git-push            Create and push the vX.Y.Z tag after a successful upload
  --dry-run             Print the resolved configuration and commands, do nothing
  -h, --help            Show this help
HELP
      exit 0
      ;;
    *)                 die "Unknown argument: $1 (try --help)" ;;
  esac
done

[[ "$APPSTORE_SKIP_UPLOAD" == "1" ]] && SKIP_UPLOAD=1

CLEAN_VERSION="${APPSTORE_VERSION#v}"
TAG="v${CLEAN_VERSION}"

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
BUILD_DIR="$ROOT/build/appstore"
ARCHIVE_PATH="$BUILD_DIR/Bixel.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
ENTITLEMENTS_PATH="$ROOT/$APPSTORE_ENTITLEMENTS"
PKG_PATH="$EXPORT_DIR/Bixel.pkg"
DERIVED_DATA="$ROOT/build/DerivedData"

# ---------------------------------------------------------------------------
# Auto build number from git commit count
# ---------------------------------------------------------------------------
if [[ -z "$APPSTORE_BUILD_NUMBER" ]]; then
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    APPSTORE_BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
  else
    APPSTORE_BUILD_NUMBER="1"
  fi
fi

# ---------------------------------------------------------------------------
# Validate configuration
# ---------------------------------------------------------------------------
validate_config() {
  local missing=()
  [[ -n "$DEVELOPMENT_TEAM" ]] || missing+=("DEVELOPMENT_TEAM")
  [[ -n "$APPSTORE_BUNDLE_ID" ]] || missing+=("APPSTORE_BUNDLE_ID")
  [[ -f "$ENTITLEMENTS_PATH" ]] || missing+=("entitlements file ($ENTITLEMENTS_PATH)")

  if [[ "$APPSTORE_SIGNING_STYLE" == "manual" ]]; then
    [[ -n "$APPSTORE_PROVISIONING_PROFILE" ]] || missing+=("APPSTORE_PROVISIONING_PROFILE")
  fi

  if [[ "$SKIP_UPLOAD" -eq 0 ]]; then
    if [[ -n "$APPSTORE_API_KEY_ID" && -n "$APPSTORE_API_ISSUER_ID" ]]; then
      :
    elif [[ -n "$APPSTORE_APPLE_ID" && -n "$APPSTORE_APP_SPECIFIC_PASSWORD" ]]; then
      :
    else
      missing+=("APPSTORE_API_KEY_ID + APPSTORE_API_ISSUER_ID (or APPSTORE_APPLE_ID + APPSTORE_APP_SPECIFIC_PASSWORD)")
    fi
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'Missing required configuration:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    die "Edit $ENV_FILE (see .env.deploy.example)."
  fi
}

# ---------------------------------------------------------------------------
# App Store Connect auth args for altool.
# Xcode 16+ altool uses --api-key/--api-issuer; older versions use
# --apiKey/--apiIssuer and require an explicit -t macos.
# ---------------------------------------------------------------------------
ALTOL_AUTH=()
ALTOL_TYPE=()
# Xcode 16+ uses the long API-key flags. On Xcode 26, invoking `altool --help`
# can block indefinitely, so do not probe the tool before a dry run or upload.
# Set BIXEL_ALTOOL_LEGACY=1 only when using an older Xcode with legacy flags.
if [[ "${BIXEL_ALTOOL_LEGACY:-0}" == "1" ]]; then
  ALTOL_NEW=0
  ALTOL_TYPE=(-t macos)
else
  ALTOL_NEW=1
fi

build_auth_args() {
  if [[ -n "$APPSTORE_API_KEY_ID" && -n "$APPSTORE_API_ISSUER_ID" ]]; then
    if [[ "$ALTOL_NEW" -eq 1 ]]; then
      ALTOL_AUTH=(--api-key "$APPSTORE_API_KEY_ID" --api-issuer "$APPSTORE_API_ISSUER_ID")
    else
      ALTOL_AUTH=(--apiKey "$APPSTORE_API_KEY_ID" --apiIssuer "$APPSTORE_API_ISSUER_ID")
    fi
  else
    ALTOL_AUTH=(-u "$APPSTORE_APPLE_ID" -p "$APPSTORE_APP_SPECIFIC_PASSWORD")
  fi
}

# ---------------------------------------------------------------------------
# Print plan
# ---------------------------------------------------------------------------
log "Configuration"
cat <<EOF
  version:        $CLEAN_VERSION ($TAG)
  build number:   $APPSTORE_BUILD_NUMBER
  bundle id:      $APPSTORE_BUNDLE_ID
  team:           $DEVELOPMENT_TEAM
  signing:        $APPSTORE_SIGNING_STYLE
  identity:       $APPSTORE_CODE_SIGN_IDENTITY
  profile:        ${APPSTORE_PROVISIONING_PROFILE:-(automatic)}
  entitlements:   $ENTITLEMENTS_PATH
  archive:        $ARCHIVE_PATH
  pkg:            $PKG_PATH
  skip upload:    $SKIP_UPLOAD
  git push:       $APPSTORE_GIT_PUSH
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry run — no changes made."
  exit 0
fi

validate_config
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found (install Xcode)."
command -v xcodegen   >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)."

mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

# ---------------------------------------------------------------------------
# 1. Version + project
# ---------------------------------------------------------------------------
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

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  PROJECT_YML_BACKUP="$(mktemp "${TMPDIR:-/tmp}/bixel-project-yml.XXXXXX")"
  cp -p "$PROJECT_YML" "$PROJECT_YML_BACKUP"

  log "Setting version $CLEAN_VERSION ($APPSTORE_BUILD_NUMBER) in project.yml"
  /usr/bin/sed -i '' "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: \"$CLEAN_VERSION\"/" "$PROJECT_YML"
  /usr/bin/sed -i '' "s/CFBundleVersion: .*/CFBundleVersion: \"$APPSTORE_BUILD_NUMBER\"/" "$PROJECT_YML"

  log "Generating Xcode project"
  (cd "$ROOT" && xcodegen generate)

  log "Building Rust engine"
  (cd "$ROOT" && ./scripts/build-rust.sh)
fi

# ---------------------------------------------------------------------------
# 2. ExportOptions.plist
# ---------------------------------------------------------------------------
log "Writing ExportOptions.plist"
if [[ "$APPSTORE_SIGNING_STYLE" == "manual" ]]; then
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$DEVELOPMENT_TEAM</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>installerSigningCertificate</key>
	<string>${APPSTORE_INSTALLER_SIGN_IDENTITY:-3rd Party Mac Developer Installer}</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$APPSTORE_BUNDLE_ID</key>
		<string>$APPSTORE_PROVISIONING_PROFILE</string>
	</dict>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
else
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$DEVELOPMENT_TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
fi

# ---------------------------------------------------------------------------
# 3. Archive
# ---------------------------------------------------------------------------
SIGN_ARGS=(
  "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
  "PRODUCT_BUNDLE_IDENTIFIER=$APPSTORE_BUNDLE_ID"
  "CODE_SIGN_ENTITLEMENTS=$ENTITLEMENTS_PATH"
  "CODE_SIGN_STYLE=$([[ "$APPSTORE_SIGNING_STYLE" == "manual" ]] && echo Manual || echo Automatic)"
)

if [[ "$APPSTORE_SIGNING_STYLE" == "manual" ]]; then
  SIGN_ARGS+=(
    "CODE_SIGN_IDENTITY=$APPSTORE_CODE_SIGN_IDENTITY"
    "PROVISIONING_PROFILE_SPECIFIER=$APPSTORE_PROVISIONING_PROFILE"
  )
else
  SIGN_ARGS+=("CODE_SIGN_IDENTITY=Apple Distribution")
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log "Archiving (Release)…"
  ARCHIVE_CMD=(
    xcodebuild archive
    -project "$ROOT/Bixel.xcodeproj"
    -scheme Bixel
    -configuration Release
    -destination "generic/platform=macOS"
    -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$DERIVED_DATA"
    "${SIGN_ARGS[@]}"
  )
  if [[ "$APPSTORE_SIGNING_STYLE" == "automatic" ]]; then
    ARCHIVE_CMD+=(-allowProvisioningUpdates)
  fi
  (cd "$ROOT" && "${ARCHIVE_CMD[@]}")
fi

[[ -d "$ARCHIVE_PATH" ]] || die "Archive not found at $ARCHIVE_PATH (run without --skip-build)."

if [[ "$ARCHIVE_ONLY" -eq 1 ]]; then
  log "Archive only — done: $ARCHIVE_PATH"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Export signed .pkg
# ---------------------------------------------------------------------------
log "Exporting signed App Store package…"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
EXPORT_CMD=(
  xcodebuild -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_DIR"
  -exportOptionsPlist "$EXPORT_OPTIONS"
)
if [[ "$APPSTORE_SIGNING_STYLE" == "automatic" ]]; then
  EXPORT_CMD+=(-allowProvisioningUpdates)
fi
(cd "$ROOT" && "${EXPORT_CMD[@]}")

[[ -f "$PKG_PATH" ]] || die "Expected .pkg not found at $PKG_PATH"

log "Packaged: $PKG_PATH ($(du -h "$PKG_PATH" | cut -f1))"

if [[ "$SKIP_UPLOAD" -eq 1 ]]; then
  log "Skip upload — package is ready for Transporter/altool."
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Validate + upload
# ---------------------------------------------------------------------------
build_auth_args

# Ensure the API private key is discoverable by altool (./private_keys).
if [[ -n "$APPSTORE_API_KEY_PATH" && -f "$APPSTORE_API_KEY_PATH" ]]; then
  mkdir -p "$ROOT/private_keys"
  cp "$APPSTORE_API_KEY_PATH" "$ROOT/private_keys/AuthKey_${APPSTORE_API_KEY_ID}.p8"
fi

log "Validating with App Store Connect…"
(cd "$ROOT" && xcrun altool --validate-app "$PKG_PATH" ${ALTOL_TYPE[@]+"${ALTOL_TYPE[@]}"} "${ALTOL_AUTH[@]}")

log "Uploading to App Store Connect…"
(cd "$ROOT" && xcrun altool --upload-app -f "$PKG_PATH" ${ALTOL_TYPE[@]+"${ALTOL_TYPE[@]}"} "${ALTOL_AUTH[@]}")

log "Upload complete. The build will appear under App Store Connect → TestFlight/Builds."

# ---------------------------------------------------------------------------
# 6. Optional git tag + push
# ---------------------------------------------------------------------------
if [[ "$APPSTORE_GIT_PUSH" == "1" ]]; then
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    warn "Tag $TAG already exists; pushing it as-is."
  else
    log "Creating tag $TAG"
    git -C "$ROOT" tag -a "$TAG" -m "Bixel Studio $TAG"
  fi
  log "Pushing tag $TAG to $APPSTORE_GIT_REMOTE"
  git -C "$ROOT" push "$APPSTORE_GIT_REMOTE" "$TAG"
fi

log "Done."
