#!/usr/bin/env bash
# Shared dotenv loader for build scripts. Source this file before calling
# load_build_env from a script that needs build-time app configuration.

load_build_env() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

require_build_env_value() {
  local value="$1"
  local name="$2"
  [[ -n "${value//[[:space:]]/}" ]] || {
    printf 'error: %s is not configured\n' "$name" >&2
    return 1
  }
}

mask_build_secret() {
  local value="$1"
  if [[ ${#value} -le 4 ]]; then
    printf '****'
  else
    printf '…%s' "${value: -4}"
  fi
}
