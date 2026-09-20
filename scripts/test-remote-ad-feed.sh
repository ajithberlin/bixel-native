#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bixel-remote-ad-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

SOURCES=()
while IFS= read -r source; do
    [[ "$source" == */BixelApp.swift ]] || SOURCES+=("$source")
done < <(rg --files "$ROOT/app/Bixel" -g '*.swift')

xcrun swiftc -module-name BixelRemoteAdTests \
    -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    -import-objc-header "$ROOT/app/Bixel/Support/Bixel-Bridging-Header.h" \
    -I "$ROOT/generated" -L "${BIXEL_TEST_LIBRARY_DIR:-$ROOT/generated}" -lbixel \
    -framework Security -framework CoreFoundation -framework SystemConfiguration \
    -module-cache-path "$TEST_DIR/cache" \
    "${SOURCES[@]}" "$ROOT/tests/RemoteAdFeedTests.swift" -o "$TEST_DIR/tests"

"$TEST_DIR/tests"
