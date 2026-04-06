// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";

/// @dev Aerodrome veAERO uses a positional array for owner→token enumeration
interface IVeAERO {
    function balanceOf(address owner) external view returns (uint256);
    /// @notice Array indexed by position: ownerToNFTokenIdList(owner, 0) → first tokenId,
    ///         ownerToNFTokenIdList(owner, 1) → second, ..., up to balanceOf(owner)-1
    function ownerToNFTokenIdList(address owner, uint256 index) external view returns (uint256);
}

/**
 * @title RemoveAllNFTsFromOldPMs
 * @dev Script to remove all veNFTs from aerodrome and aerodrome-usdc factories
 *      on two old PortfolioManagers.
 *
 * Old PMs:
 *   - 0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5
 *   - 0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9
 *
 * Factory salts tried: "aerodrome", "aerodrome-usdc"
 *
 * The script has two modes:
 *   1. scan()   - View-only: enumerates all portfolios and their veNFTs across both old PMs
 *   2. run()    - Broadcast: removes all veNFTs from the caller's portfolios on both old PMs
 *
 * Usage:
 *   # Dry run - scan all portfolios and NFTs
 *   forge script script/portfolio_account/helper/RemoveAllNFTsFromOldPMs.s.sol:RemoveAllNFTsFromOldPMs --sig "scan()" --rpc-url $BASE_RPC_URL
 *
 *   # Execute removal for caller's portfolios
 *   forge script script/portfolio_account/helper/RemoveAllNFTsFromOldPMs.s.sol:RemoveAllNFTsFromOldPMs --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
 */
contract RemoveAllNFTsFromOldPMs is Script {
    address constant OLD_PM_1 = 0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5;
    address constant OLD_PM_2 = 0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9;
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;

    bytes32 constant AERODROME_SALT = keccak256(abi.encodePacked("aerodrome"));
    bytes32 constant AERODROME_USDC_SALT = keccak256(abi.encodePacked("aerodrome-usdc"));

    IVeAERO constant ve = IVeAERO(VOTING_ESCROW);

    // ───────────────────────────────────────────────
    // View-only scan
    // ───────────────────────────────────────────────

    /// @notice Enumerate all portfolios and their veNFTs across both old PMs (no tx)
    function scan() external view {
        _scanPM(OLD_PM_1, "Old PM 1");
        _scanPM(OLD_PM_2, "Old PM 2");
    }

    function _scanPM(address pmAddr, string memory label) internal view {
        PortfolioManager pm = PortfolioManager(pmAddr);
        console.log("===========================================");
        console.log(label, pmAddr);
        console.log("===========================================");

        _scanFactory(pm, AERODROME_SALT, "aerodrome");
        _scanFactory(pm, AERODROME_USDC_SALT, "aerodrome-usdc");
    }

    function _scanFactory(PortfolioManager pm, bytes32 salt, string memory saltName) internal view {
        address factoryAddr = pm.factoryBySalt(salt);
        if (factoryAddr == address(0)) {
            console.log("  Factory not found for salt:", saltName);
            return;
        }

        PortfolioFactory factory = PortfolioFactory(factoryAddr);
        console.log("  Factory:", saltName, factoryAddr);

        uint256 portfolioCount = factory.getPortfoliosLength();
        console.log("  Portfolio count:", portfolioCount);

        for (uint256 i = 0; i < portfolioCount; i++) {
            address portfolio = factory.getPortfolio(i);
            address owner = factory.ownerOf(portfolio);

            uint256 nftCount = ve.balanceOf(portfolio);
            console.log("    Portfolio:", portfolio);
            console.log("      Owner:", owner);
            console.log("      NFT count:", nftCount);

            for (uint256 j = 0; j < nftCount; j++) {
                uint256 tokenId = ve.ownerToNFTokenIdList(portfolio, j);
                console.log("      Token ID:", tokenId);
            }
        }
    }

    // ───────────────────────────────────────────────
    // Broadcast removal
    // ───────────────────────────────────────────────

    /// @notice Remove all veNFTs from the caller's portfolios on both old PMs
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(privateKey);

        console.log("Caller:", caller);

        vm.startBroadcast(privateKey);

        _removeFromPM(PortfolioManager(OLD_PM_1), caller, "Old PM 1");
        _removeFromPM(PortfolioManager(OLD_PM_2), caller, "Old PM 2");

        vm.stopBroadcast();
    }

    function _removeFromPM(PortfolioManager pm, address caller, string memory label) internal {
        console.log("---", label, address(pm), "---");
        _removeFromFactory(pm, AERODROME_SALT, caller, "aerodrome");
        _removeFromFactory(pm, AERODROME_USDC_SALT, caller, "aerodrome-usdc");
    }

    function _removeFromFactory(
        PortfolioManager pm,
        bytes32 salt,
        address caller,
        string memory saltName
    ) internal {
        address factoryAddr = pm.factoryBySalt(salt);
        if (factoryAddr == address(0)) {
            console.log("  No factory for salt:", saltName);
            return;
        }

        PortfolioFactory factory = PortfolioFactory(factoryAddr);
        address portfolio = factory.portfolioOf(caller);
        if (portfolio == address(0)) {
            console.log("  No portfolio for caller in:", saltName);
            return;
        }

        uint256 nftCount = ve.balanceOf(portfolio);
        if (nftCount == 0) {
            console.log("  No NFTs in portfolio for:", saltName);
            return;
        }

        console.log("  Removing", nftCount, "NFTs from", saltName);

        // Collect all token IDs by position index
        uint256[] memory tokenIds = new uint256[](nftCount);
        for (uint256 i = 0; i < nftCount; i++) {
            tokenIds[i] = ve.ownerToNFTokenIdList(portfolio, i);
        }

        // Remove one token per multicall so each passes collateral requirements individually
        bytes4 selector = BaseCollateralFacet.removeCollateral.selector;
        bytes[] memory calldatas = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = factoryAddr;

        for (uint256 i = 0; i < nftCount; i++) {
            console.log("    Removing token ID:", tokenIds[i]);
            calldatas[0] = abi.encodeWithSelector(selector, tokenIds[i]);
            pm.multicall(calldatas, factories);
        }
        console.log("  Done! Removed", nftCount, "NFTs from", saltName);
    }
}
