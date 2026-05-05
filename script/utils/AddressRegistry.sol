// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title AddressRegistry
 * @notice Helper for deploy scripts to persist deployed addresses into the
 *         JSON registry under `addresses/{network}/{platform}.json`.
 *
 * @dev    The output of every deploy is captured by calling `record()` so the
 *         contract dev never copy-pastes hex addresses by hand. The registry
 *         files are then consumed by the published npm package
 *         ("40acres/contracts") and homestead's abigen pipeline.
 *
 *         Network is auto-detected from `block.chainid`. The `dotPath`
 *         argument selects the JSON key under `.contracts`, including the
 *         `dev` / `prod` env suffix. Examples:
 *
 *           record(vm, "aerodrome", "portfolioManager.prod", deployed);
 *           record(vm, "aerodrome", "strategies.usdc-loan.factory.dev", deployed);
 *
 *         The parent path must already exist in the JSON file (the schema is
 *         described in addresses/README.md). For brand-new keys, edit the JSON
 *         once to add the parent object, then `record()` updates from then on.
 */
library AddressRegistry {
    /// @notice Records `addr` at `addresses/{network}/{platform}.json` under
    ///         `.contracts.{dotPath}`. Reverts on unknown chainId.
    function record(
        Vm vm,
        string memory platform,
        string memory dotPath,
        address addr
    ) internal {
        string memory file = string.concat(
            vm.projectRoot(),
            "/addresses/",
            networkFromChainId(block.chainid),
            "/",
            platform,
            ".json"
        );
        string memory key = string.concat(".contracts.", dotPath);
        vm.writeJson(vm.toString(addr), file, key);
    }

    /// @notice Convenience: writes to `.contracts.{dotPath}.{env}` where env
    ///         is "dev" or "prod" depending on the `IS_DEV` env var
    ///         (defaults to false → prod).
    function recordEnv(
        Vm vm,
        string memory platform,
        string memory dotPath,
        address addr
    ) internal {
        bool isDev = vm.envOr("IS_DEV", false);
        record(
            vm,
            platform,
            string.concat(dotPath, ".", isDev ? "dev" : "prod"),
            addr
        );
    }

    /// @notice Maps chainId → directory name under addresses/. Keep in sync
    ///         with addresses/validate.sh:expected_network_for().
    function networkFromChainId(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 1)     return "mainnet";
        if (chainId == 10)    return "optimism";
        if (chainId == 8453)  return "base";
        if (chainId == 43114) return "avalanche";
        revert("AddressRegistry: unknown chainId -- add it to networkFromChainId() and addresses/validate.sh");
    }

    /// @notice Returns every V2 platform on `chainId` -- i.e. the platforms
    ///         using the portfolio account architecture and exposing
    ///         `portfolioManager`/`walletFactory`/`strategies` in their
    ///         addresses file. Used by `recordChainLevel()` so chain-level
    ///         deployments fan out to every platform on the chain.
    ///
    /// @dev    When a platform migrates V1 -> V2 (e.g. blackhole), add it
    ///         here AND populate the new V2 fields in its addresses file
    ///         (so `vm.writeJson` has a parent path to write into).
    function v2PlatformsOnChain(uint256 chainId) internal pure returns (string[] memory) {
        if (chainId == 1) {
            string[] memory s = new string[](2);
            s[0] = "supernova";
            s[1] = "yieldbasis-eth";
            return s;
        }
        if (chainId == 8453) {
            string[] memory s = new string[](1);
            s[0] = "aerodrome";
            return s;
        }
        if (chainId == 10) {
            string[] memory s = new string[](1);
            s[0] = "velodrome";
            return s;
        }
        if (chainId == 43114) {
            // blackhole stays V1-only until V2 ships there.
            string[] memory s = new string[](1);
            s[0] = "pharaoh";
            return s;
        }
        revert("AddressRegistry: no V2 platforms registered for this chainId");
    }

    /// @notice Records `addr` under `.contracts.{dotPath}` in every V2
    ///         platform file on the current chain. Use for chain-level
    ///         contracts like PortfolioManager and WalletFactory whose
    ///         CREATE2 address is identical across platforms on the chain.
    function recordChainLevel(
        Vm vm,
        string memory dotPath,
        address addr
    ) internal {
        string[] memory platforms = v2PlatformsOnChain(block.chainid);
        for (uint256 i = 0; i < platforms.length; i++) {
            record(vm, platforms[i], dotPath, addr);
        }
    }
}
