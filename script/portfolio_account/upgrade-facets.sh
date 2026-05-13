#!/usr/bin/env bash
#
# Usage: ./upgrade-facets.sh <platform> <facet1,facet2,...>
#
# Wraps the per-facet scripts in script/portfolio_account/facets/. Reads
# per-platform addresses from script/portfolio_account/env/<platform>.env.
#
# Env knobs:
#   DRY_RUN=1            print commands without --broadcast/--verify
#   EXTRA_FORGE_ARGS=... appended to every forge invocation
#   PROFILE=...          FOUNDRY_PROFILE; unset by default
#
set -euo pipefail

PLATFORM="${1:-}"
FACETS_CSV="${2:-}"

if [[ -z "$PLATFORM" || -z "$FACETS_CSV" ]]; then
  echo "usage: make upgrade PLATFORM=<name> FACETS=<csv>" >&2
  echo "       PLATFORM must match script/portfolio_account/env/<name>.env" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env/$PLATFORM.env"
FACETS_DIR="$SCRIPT_DIR/facets"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "no env file at $ENV_FILE" >&2
  echo "available: $(ls "$SCRIPT_DIR/env"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' | tr '\n' ' ')" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Layer chain-local overrides (USDC, RPC, CHAIN_ID, SWAP_CONFIG, etc.) when
# CHAIN is set. Lets the same PLATFORM env be reused across many leaf chains.
if [[ -n "${CHAIN:-}" ]]; then
  CHAIN_ENV_FILE="$SCRIPT_DIR/env/chains/$CHAIN.env"
  if [[ ! -f "$CHAIN_ENV_FILE" ]]; then
    echo "no chain env at $CHAIN_ENV_FILE" >&2
    echo "available: $(ls "$SCRIPT_DIR/env/chains"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' | tr '\n' ' ')" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  source "$CHAIN_ENV_FILE"
fi
# Foundry treats $CHAIN as a chain alias; unset so cast/forge don't try to
# parse our internal chain name ("ink") as a chain id.
unset CHAIN

: "${CHAIN_ID:?CHAIN_ID not set in $ENV_FILE}"
: "${RPC_URL_VAR:?RPC_URL_VAR not set in $ENV_FILE}"
RPC_URL="${!RPC_URL_VAR:-}"
if [[ -z "$RPC_URL" ]]; then
  echo "\$$RPC_URL_VAR is not set in your shell — export it (typically in your .env)" >&2
  exit 2
fi

# Derive PORTFOLIO_FACTORY / LOAN_CONFIG / VAULT on-chain from FACTORY_SALT.
# Explicit env-file `export`s always win (override-by-set semantics).
# PORTFOLIO_MANAGER defaults to the canonical 40Acres deployment.
: "${PORTFOLIO_MANAGER:=0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec}"
_zero_or_empty() { [[ -z "${1:-}" || "$1" == 0x0000000000000000000000000000000000000000 ]]; }
if _zero_or_empty "${PORTFOLIO_FACTORY:-}" && [[ -n "${FACTORY_SALT:-}" ]]; then
  if ! command -v cast >/dev/null 2>&1; then
    echo "cast (foundry) required to derive factory from FACTORY_SALT" >&2
    exit 2
  fi
  salt_hash="$(cast keccak "$FACTORY_SALT")"
  PORTFOLIO_FACTORY="$(cast call "$PORTFOLIO_MANAGER" "factoryBySalt(bytes32)(address)" "$salt_hash" --rpc-url "$RPC_URL")"
  export PORTFOLIO_FACTORY
  echo "derived from salt \"$FACTORY_SALT\":"
  echo "  PORTFOLIO_FACTORY=$PORTFOLIO_FACTORY"
  if [[ "$PORTFOLIO_FACTORY" == 0x0000000000000000000000000000000000000000 ]]; then
    echo "  (PortfolioManager has no factory at this salt — deploy first)" >&2
    exit 2
  fi
  if _zero_or_empty "${LOAN_CONFIG:-}" || _zero_or_empty "${VAULT:-}"; then
    cfg="$(cast call "$PORTFOLIO_FACTORY" "portfolioFactoryConfig()(address)" --rpc-url "$RPC_URL")"
    if _zero_or_empty "${LOAN_CONFIG:-}"; then
      LOAN_CONFIG="$(cast call "$cfg" "getLoanConfig()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x0000000000000000000000000000000000000000")"
      export LOAN_CONFIG
      echo "  LOAN_CONFIG=$LOAN_CONFIG"
    fi
    if _zero_or_empty "${VAULT:-}"; then
      # No-loan platforms (e.g. SuperNova) have no vault — tolerate revert.
      VAULT="$(cast call "$cfg" "getVault()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x0000000000000000000000000000000000000000")"
      export VAULT
      echo "  VAULT=$VAULT"
    fi
  fi
fi

# Map a CSV facet name to its DeployXxxFacet.s.sol filename.
facet_to_script() {
  case "$1" in
    bridge)             echo "DeployBridgeFacet.s.sol:DeployBridgeFacet" ;;
    claiming)           echo "DeployClaimingFacet.s.sol:DeployClaimingFacet" ;;
    collateral)         echo "DeployCollateralFacet.s.sol:DeployCollateralFacet" ;;
    lending)            echo "DeployLendingFacet.s.sol:DeployLendingFacet" ;;
    voting)             echo "DeployVotingFacet.s.sol:DeployVotingFacet" ;;
    voting-escrow)      echo "DeployVotingEscrowFacet.s.sol:DeployVotingEscrowFacet" ;;
    migration)          echo "DeployMigrationFacet.s.sol:DeployMigrationFacet" ;;
    wallet)             echo "DeployWalletFacet.s.sol:DeployWalletFacet" ;;
    marketplace)        echo "DeployMarketplaceFacets.s.sol:DeployMarketplaceFacet" ;;
    vexy)               echo "DeployMarketplaceFacets.s.sol:DeployVexyFacet" ;;
    openx)              echo "DeployMarketplaceFacets.s.sol:DeployOpenXFacet" ;;
    forty-acres-marketplace) echo "DeployMarketplaceFacets.s.sol:DeployFortyAcresMarketplaceFacet" ;;
    rewards-processing) echo "DeployRewardsProcessingFacet.s.sol:DeployRewardsProcessingFacet" ;;
    erc721-receiver)    echo "DeployERC721ReceiverFacet.s.sol:DeployERC721ReceiverFacet" ;;
    erc4626-claiming)   echo "DeployERC4626ClaimingFacet.s.sol:DeployERC4626ClaimingFacet" ;;
    erc4626-collateral) echo "DeployERC4626CollateralFacet.s.sol:DeployERC4626CollateralFacet" ;;
    erc4626-lending)    echo "DeployERC4626LendingFacet.s.sol:DeployERC4626LendingFacet" ;;
    superchain-voting)  echo "DeploySuperchainVoting.s.sol:DeploySuperchainVotingFacet" ;;
    superchain-claiming) echo "DeploySuperchainClaimingFacet.s.sol:DeploySuperchainClaimingFacet" ;;
    # Blackhole and SuperNova share the same facet variants; aliases below
    # both resolve to the same contracts in DeployBlackholeFacets.s.sol.
    blackhole-claiming | supernova-claiming) echo "DeployBlackholeFacets.s.sol:DeployBlackholeClaimingFacet" ;;
    blackhole-collateral | supernova-collateral) echo "DeployBlackholeFacets.s.sol:DeployBlackholeCollateralFacet" ;;
    blackhole-voting-escrow | supernova-voting-escrow) echo "DeployBlackholeFacets.s.sol:DeployBlackholeVotingEscrowFacet" ;;
    blackhole-rewards-processing | supernova-rewards-processing) echo "DeployBlackholeFacets.s.sol:DeployBlackholeRewardsProcessingFacet" ;;
    blackhole-marketplace | supernova-marketplace) echo "DeployBlackholeFacets.s.sol:DeployBlackholeMarketplaceFacet" ;;
    rewards-config)     echo "DeployRewardsConfigFacet.s.sol:DeployRewardsConfigFacet" ;;
    *)
      echo "" ;;
  esac
}

# Iterate CSV (split on commas, trim whitespace)
IFS=',' read -ra FACETS <<< "$FACETS_CSV"
for raw in "${FACETS[@]}"; do
  facet="$(echo "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -z "$facet" ]] && continue
  target="$(facet_to_script "$facet")"
  if [[ -z "$target" ]]; then
    echo "unknown facet: '$facet'" >&2
    echo "see script/portfolio_account/env/README.md for the list" >&2
    exit 2
  fi
  script_file="${target%%:*}"
  if [[ ! -f "$FACETS_DIR/$script_file" ]]; then
    echo "script not found: $FACETS_DIR/$script_file" >&2
    exit 2
  fi

  echo
  echo "==> upgrading $facet on $PLATFORM (chain $CHAIN_ID)"

  base_args=(
    forge script "$FACETS_DIR/$target"
    --chain-id "$CHAIN_ID"
    --rpc-url "$RPC_URL"
    --via-ir
  )
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run]" "${base_args[@]}" ${EXTRA_FORGE_ARGS:-}
    continue
  fi
  base_args+=(--broadcast --verify)
  if [[ -n "${VERIFIER:-}" ]]; then
    base_args+=(--verifier "$VERIFIER")
    [[ -n "${VERIFIER_URL:-}" ]] && base_args+=(--verifier-url "$VERIFIER_URL")
  fi
  if [[ -n "${EXTRA_FORGE_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra=( ${EXTRA_FORGE_ARGS} )
    base_args+=( "${extra[@]}" )
  fi
  "${base_args[@]}"
done

echo
echo "==> done"
