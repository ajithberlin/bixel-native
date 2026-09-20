#!/usr/bin/env bash
#
# Build the Rust engine and stage the artifacts (static library + C header)
# that the Xcode target links against.
#
# Usage:  scripts/build-rust.sh [--universal]
#
#   --universal   build a fat arm64 + x86_64 static library (macOS only).
#
# Requires: cargo (Rust toolchain), cbindgen.

set -euo pipefail

# Xcode build scripts run with a minimal PATH; restore common toolchain paths.
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/generated"
mkdir -p "$OUT"

command -v cargo >/dev/null 2>&1 || { echo "error: cargo not found" >&2; exit 1; }
command -v cbindgen >/dev/null 2>&1 || { echo "error: cbindgen not found (cargo install cbindgen)" >&2; exit 1; }

TARGET_PLATFORM="${PLATFORM_NAME:-}"
ARG="${1:-}"

if [[ "$ARG" == "--ios" ]] || [[ "$TARGET_PLATFORM" == "iphoneos" ]]; then
  echo "==> Building Rust core for iOS (aarch64-apple-ios)"
  export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
  (cd "$ROOT" && cargo build --release -p bixel-ffi --target aarch64-apple-ios)
  cp "$ROOT/target/aarch64-apple-ios/release/libbixel.a" "$OUT/libbixel.a"
elif [[ "$ARG" == "--ios-sim" ]] || [[ "$TARGET_PLATFORM" == "iphonesimulator" ]]; then
  echo "==> Building Rust core for iOS Simulator (aarch64-apple-ios-sim)"
  export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
  (cd "$ROOT" && cargo build --release -p bixel-ffi --target aarch64-apple-ios-sim)
  cp "$ROOT/target/aarch64-apple-ios-sim/release/libbixel.a" "$OUT/libbixel.a"
elif [[ "$ARG" == "--universal" ]]; then
  echo "==> Building universal (arm64 + x86_64) static library"
  for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    if rustup target list --installed 2>/dev/null | grep -q "$TARGET"; then
      (cd "$ROOT" && cargo build --release -p bixel-ffi --target "$TARGET")
    fi
  done
  SLICES=()
  for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    LIB="$ROOT/target/$TARGET/release/libbixel.a"
    [[ -f "$LIB" ]] && SLICES+=("$LIB")
  done
  if [[ "${#SLICES[@]}" -gt 0 ]]; then
    lipo -create "${SLICES[@]}" -output "$OUT/libbixel.a"
  else
    cp "$ROOT/target/release/libbixel.a" "$OUT/libbixel.a"
  fi
else
  echo "==> Building Rust core (release)"
  (cd "$ROOT" && cargo build --release -p bixel-ffi)
  cp "$ROOT/target/release/libbixel.a" "$OUT/libbixel.a"
fi

echo "==> Generating C header (cbindgen)"
(cd "$ROOT" && cbindgen --config cbindgen.toml --crate bixel-ffi --output "$OUT/bixel.h")

echo "==> Staged: $OUT/libbixel.a, $OUT/bixel.h"
