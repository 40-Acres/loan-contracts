#!/usr/bin/env bash
#
# Usage: ./verify-contract.sh <chain> <address> <contract_path:Name>
#
# Wraps `forge verify-contract` using the chain's VERIFIER / VERIFIER_URL /
# CHAIN_ID from script/portfolio_account/env/chains/<chain>.env.
#
# Extra args (constructor-args, libraries, etc.) can be supplied via
# VERIFY_ARGS, e.g.:
#   VERIFY_ARGS="--constructor-args $(cast abi-encode 'constructor(address,bytes)' 0x.. 0x..)" \
#     make verify CHAIN=ink ADDRESS=0x.. CONTRACT=...:ERC1967Proxy
#
set -euo pipefail

CHAIN="${1:-}"
ADDRESS="${2:-}"
CONTRACT="${3:-}"
if [[ -z "$CHAIN" || -z "$ADDRESS" || -z "$CONTRACT" ]]; then
  echo "usage: make verify CHAIN=<name> ADDRESS=<0x..> CONTRACT=<path:Name>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN_ENV_FILE="$SCRIPT_DIR/env/chains/$CHAIN.env"
if [[ ! -f "$CHAIN_ENV_FILE" ]]; then
  echo "no chain env at $CHAIN_ENV_FILE" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$CHAIN_ENV_FILE"

: "${CHAIN_ID:?CHAIN_ID not set in $CHAIN_ENV_FILE}"

args=(
  forge verify-contract "$ADDRESS" "$CONTRACT"
  --chain-id "$CHAIN_ID"
  --watch
)
if [[ -n "${VERIFIER:-}" ]]; then
  args+=(--verifier "$VERIFIER")
  [[ -n "${VERIFIER_URL:-}" ]] && args+=(--verifier-url "$VERIFIER_URL")
fi
if [[ -n "${VERIFY_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra=( ${VERIFY_ARGS} )
  args+=( "${extra[@]}" )
fi

echo "==> verifying $ADDRESS ($CONTRACT) on $CHAIN (chain $CHAIN_ID)"
"${args[@]}"
