#!/usr/bin/env bash
#
# Usage: ./deploy-swap-config.sh <chain>
#
# Reads script/portfolio_account/env/chains/<chain>.env for CHAIN_ID +
# RPC_URL_VAR, then runs the DeploySwapConfig forge script.
#
# Optional envs:
#   APPROVED_SWAP_TARGETS=0xa,0xb   forwarded to the script
#   DRY_RUN=1                       skip --broadcast/--verify
#   EXTRA_FORGE_ARGS=...            appended
#
set -euo pipefail

CHAIN="${1:-}"
if [[ -z "$CHAIN" ]]; then
  echo "usage: make deploy-swap-config CHAIN=<name>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN_ENV_FILE="$SCRIPT_DIR/env/chains/$CHAIN.env"
if [[ ! -f "$CHAIN_ENV_FILE" ]]; then
  echo "no chain env at $CHAIN_ENV_FILE" >&2
  echo "available: $(ls "$SCRIPT_DIR/env/chains"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' | tr '\n' ' ')" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$CHAIN_ENV_FILE"

: "${CHAIN_ID:?CHAIN_ID not set in $CHAIN_ENV_FILE}"
: "${RPC_URL_VAR:?RPC_URL_VAR not set in $CHAIN_ENV_FILE}"
RPC_URL="${!RPC_URL_VAR:-}"
if [[ -z "$RPC_URL" ]]; then
  echo "\$$RPC_URL_VAR is not set in your shell" >&2
  exit 2
fi

echo "==> deploying SwapConfig on $CHAIN (chain $CHAIN_ID)"
# Foundry treats $CHAIN as a chain alias; unset so cast/forge don't parse
# our internal chain name ("ink") as a chain id.
unset CHAIN
if [[ -n "${APPROVED_SWAP_TARGETS:-}" ]]; then
  echo "    seeding approved targets: $APPROVED_SWAP_TARGETS"
fi

args=(
  forge script "$SCRIPT_DIR/DeploySwapConfig.s.sol:DeploySwapConfig"
  --chain-id "$CHAIN_ID"
  --rpc-url "$RPC_URL"
  --via-ir
)
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[dry-run]" "${args[@]}" ${EXTRA_FORGE_ARGS:-}
  exit 0
fi
args+=(--broadcast --verify)
if [[ -n "${VERIFIER:-}" ]]; then
  args+=(--verifier "$VERIFIER")
  [[ -n "${VERIFIER_URL:-}" ]] && args+=(--verifier-url "$VERIFIER_URL")
fi
if [[ -n "${EXTRA_FORGE_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra=( ${EXTRA_FORGE_ARGS} )
  args+=( "${extra[@]}" )
fi
"${args[@]}"

echo
echo "==> done. Update SWAP_CONFIG in $CHAIN_ENV_FILE with the proxy address printed above."
