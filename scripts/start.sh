#!/usr/bin/env bash
#
# Bixel Studio — Quick Start Script
# Usage: ./scripts/start.sh [--build | --run]
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== Bixel Studio Setup ==="

# 1. Check prerequisites
if ! command -v cargo >/dev/null 2>&1; then
  echo "Error: Rust toolchain (cargo) is required. Install from https://rustup.rs" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

# 2. Setup dev environment file if missing
if [[ ! -f .env && ! -f .env.dev ]]; then
  if [[ -f .env.dev.example ]]; then
    echo "-> Creating .env.dev from template..."
    cp .env.dev.example .env.dev
  fi
fi

# 3. Generate Xcode project
echo "-> Generating Xcode project..."
xcodegen generate

# 4. Run or Open
ACTION="${1:-}"

if [[ "$ACTION" == "--run" || "$ACTION" == "--build" ]]; then
  echo "-> Building Bixel (Debug)..."
  xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' build

  BUILD_DIR="$(xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' -showBuildSettings | awk -F ' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')"
  APP_PATH="$BUILD_DIR/Bixel.app"

  if [[ "$ACTION" == "--run" && -d "$APP_PATH" ]]; then
    echo "-> Launching Bixel Studio..."
    open "$APP_PATH"
  fi
else
  echo "-> Opening Bixel.xcodeproj in Xcode..."
  open Bixel.xcodeproj
  echo ""
  echo "✅ Done! Press Cmd+R in Xcode to run Bixel Studio."
  echo "   (Or run './scripts/start.sh --run' to build and launch from terminal)"
fi
