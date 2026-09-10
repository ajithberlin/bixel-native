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

echo "RevenueCat production and development configuration paths are valid"
