#!/usr/bin/env bash
#
# Validates every JSON file under addresses/ against the schema documented in
# addresses/README.md. Run by CI and locally:
#
#   bash addresses/validate.sh
#
# Exit code 0 = all valid. Non-zero = at least one error. Zero-address sentinels
# produce warnings (printed) but do not fail the run.

set -euo pipefail

cd "$(dirname "$0")/.."  # repo root

errors=0
warnings=0
files_checked=0

# chainId → network name (sanity check). Kept as a case statement for
# bash 3.2 compatibility (macOS default).
expected_network_for() {
  case "$1" in
    1)     echo "mainnet" ;;
    10)    echo "optimism" ;;
    8453)  echo "base" ;;
    43114) echo "avalanche" ;;
    *)     echo "" ;;
  esac
}

ZERO_ADDR="0x0000000000000000000000000000000000000000"
ADDR_REGEX='^0x[a-fA-F0-9]{40}$'

err()  { echo "❌ $1: $2"; errors=$((errors + 1)); }
warn() { echo "⚠️  $1: $2"; warnings=$((warnings + 1)); }

# Validate every leaf string under .contracts that looks like an address-shaped value.
# We treat any string matching 0x[hex] as an address and check the full regex on it.
validate_addresses_in_file() {
  local f="$1"

  # Collect every string value with key path. jq's `paths(strings)` walks the tree.
  while IFS=$'\t' read -r path value; do
    if [[ "$value" =~ ^0x ]]; then
      if [[ ! "$value" =~ $ADDR_REGEX ]]; then
        err "$f" "invalid address shape at $path: $value"
      elif [[ "$value" == "$ZERO_ADDR" ]]; then
        warn "$f" "zero-address sentinel at $path"
      fi
    fi
  done < <(jq -r '
    [paths(strings) as $p | {p: ($p | join(".")), v: getpath($p)}]
    | .[] | "\(.p)\t\(.v)"
  ' "$f")
}

# Enforce: each address node is either a flat string or {dev, prod} — never mixed,
# never partial. We look at every object that has a "dev" or "prod" key and assert
# it has BOTH and ONLY those (no extra keys).
validate_dev_prod_shape() {
  local f="$1"

  local bad
  bad=$(jq -r '
    [.. | objects | select(has("dev") or has("prod"))
      | select((keys | sort) != ["dev","prod"])]
    | length
  ' "$f")

  if [[ "$bad" -gt 0 ]]; then
    err "$f" "found $bad object(s) with partial or polluted {dev,prod} shape"
  fi
}

# Top-level shape and chainId/network consistency.
validate_top_level() {
  local f="$1"

  local chain_id network platform
  chain_id=$(jq -r '.chainId // empty' "$f")
  network=$(jq -r '.network // empty' "$f")
  platform=$(jq -r '.platform // empty' "$f")

  [[ -z "$chain_id" ]] && err "$f" "missing chainId"
  [[ -z "$network" ]]  && err "$f" "missing network"
  [[ -z "$platform" ]] && err "$f" "missing platform"
  jq -e '.contracts | type == "object"' "$f" >/dev/null \
    || err "$f" "missing or non-object contracts field"

  # chainId ↔ network name sanity check
  local expected
  expected=$(expected_network_for "$chain_id")
  if [[ -n "$expected" && "$expected" != "$network" ]]; then
    err "$f" "chainId $chain_id implies network=$expected but file says network=$network"
  fi

  # File path ↔ {network, platform} consistency: addresses/<network>/<platform>.json
  local expected_path="addresses/$network/$platform.json"
  if [[ "$f" != "$expected_path" ]]; then
    err "$f" "path mismatch — expected $expected_path"
  fi
}

# Discover every *.json under addresses/{network}/. The legacy
# addresses/addresses.json (different schema) is excluded by being one level up.
while IFS= read -r f; do
  files_checked=$((files_checked + 1))

  # Must be valid JSON before anything else.
  if ! jq -e . "$f" >/dev/null 2>&1; then
    err "$f" "invalid JSON"
    continue
  fi

  validate_top_level "$f"
  validate_dev_prod_shape "$f"
  validate_addresses_in_file "$f"
done < <(find addresses -mindepth 2 -maxdepth 2 -name '*.json' -type f | sort)

echo
echo "Checked $files_checked file(s). $errors error(s), $warnings warning(s)."
[[ "$errors" -eq 0 ]]
