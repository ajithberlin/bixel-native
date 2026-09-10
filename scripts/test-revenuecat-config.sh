#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bixel-revenuecat-config.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

PRODUCTION_ENV="$TEST_DIR/.env"
DEVELOPMENT_ENV="$TEST_DIR/.env.dev"
DEPLOY_ENV="$TEST_DIR/.env.deploy"

printf '%s\n' 'REVENUECAT_API_KEY=prod_example_key' > "$PRODUCTION_ENV"
printf '%s\n' 'REVENUECAT_API_KEY=test_example_key' > "$DEVELOPMENT_ENV"
printf '%s\n' 'DEVELOPMENT_TEAM=ABCDE12345' > "$DEPLOY_ENV"

(
  unset REVENUECAT_API_KEY
  # shellcheck disable=SC1091
  source "$ROOT/scripts/load-build-env.sh"
  load_build_env "$PRODUCTION_ENV"
  [[ "$REVENUECAT_API_KEY" == "prod_example_key" ]]
)

(
  unset REVENUECAT_API_KEY
  # shellcheck disable=SC1091
  source "$ROOT/scripts/load-build-env.sh"
  load_build_env "$DEVELOPMENT_ENV"
  [[ "$REVENUECAT_API_KEY" == "test_example_key" ]]
)

production_output="$(
  BIXEL_PRODUCTION_ENV="$PRODUCTION_ENV" \
  BIXEL_DEPLOY_ENV="$DEPLOY_ENV" \
  "$ROOT/scripts/publish-appstore.sh" --dry-run
)"
[[ "$production_output" == *"revenuecat:     …_key"* ]]
[[ "$production_output" != *"prod_example_key"* ]]

development_output="$(
  BIXEL_DEV_ENV="$DEVELOPMENT_ENV" \
  "$ROOT/scripts/package-dmg.sh" --dry-run
)"
[[ "$development_output" == *"revenuecat:  …_key"* ]]
[[ "$development_output" != *"test_example_key"* ]]

CONFIG_PLIST="$TEST_DIR/Info.plist"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>RevenueCatAPIKey</key><string>$(REVENUECAT_API_KEY)</string></dict></plist>' \
  > "$CONFIG_PLIST"

BIXEL_INFO_PLIST_PATH="$CONFIG_PLIST" \
  BIXEL_DEV_ENV="$DEVELOPMENT_ENV" \
  CONFIGURATION=Debug \
  "$ROOT/scripts/configure-revenuecat-info.sh"
[[ "$(plutil -extract RevenueCatAPIKey raw -o - "$CONFIG_PLIST")" == "test_example_key" ]]

REVENUECAT_API_KEY=prod_example_key \
  BIXEL_INFO_PLIST_PATH="$CONFIG_PLIST" \
  BIXEL_DEV_ENV="$DEVELOPMENT_ENV" \
  CONFIGURATION=Debug \
  "$ROOT/scripts/configure-revenuecat-info.sh"
[[ "$(plutil -extract RevenueCatAPIKey raw -o - "$CONFIG_PLIST")" == "prod_example_key" ]]

BIXEL_INFO_PLIST_PATH="$CONFIG_PLIST" \
BIXEL_DEV_ENV="$TEST_DIR/missing.env" \
  CONFIGURATION=Release \
  env -u REVENUECAT_API_KEY \
  "$ROOT/scripts/configure-revenuecat-info.sh"
stale_value="$(plutil -extract RevenueCatAPIKey raw -o - "$CONFIG_PLIST")"
if [[ "$stale_value" != '$(REVENUECAT_API_KEY)' ]]; then
  echo "a build without a key must clear a previously injected key" >&2
  exit 1
fi

if ! rg -q 'static let lifetimeProductID = "bixel_ad_free"' "$ROOT/app/Bixel/Models/SubscriptionManager.swift"; then
  echo "SubscriptionManager must use the App Store product ID bixel_ad_free" >&2
  exit 1
fi

echo "RevenueCat production and development configuration paths are valid"
