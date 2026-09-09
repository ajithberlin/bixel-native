#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bixel-assistant-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do
    [[ "$source" == */BixelApp.swift ]] || SOURCES+=("$source")
done < <(rg --files app/Bixel -g '*.swift')
xcrun swiftc -module-name BixelAssistantTests \
    -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    -import-objc-header app/Bixel/Support/Bixel-Bridging-Header.h \
    -I generated -L generated -lbixel \
    -framework Security -framework CoreFoundation -framework SystemConfiguration \
    -module-cache-path "$TEST_DIR/cache" \
    "${SOURCES[@]}" tests/AssistantSessionTests.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
