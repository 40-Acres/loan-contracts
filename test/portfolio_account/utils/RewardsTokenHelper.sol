// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LocalSetup} from "./LocalSetup.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";

/// @dev Minimal ERC4626 vault shim that simply reports a fixed asset address.
///      Used by `_useTokenAsRewardsAsset` to make `getRewardsToken()` resolve
///      to an arbitrary token. Tests that need this run paths where vault
///      deposit is never invoked, so the shim doesn't need real vault logic.
contract RewardsAssetShimVault {
    address public _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    /// @dev Always reverts so accidental flow into vault.deposit fails loudly.
    function deposit(uint256, address) external pure returns (uint256) {
        revert("RewardsAssetShimVault: deposit not supported");
    }
}

/**
 * @title RewardsTokenHelper
 * @dev Test base extending LocalSetup that provides `_useTokenAsRewardsAsset(token)`,
 *      a helper to swap the registered RewardsProcessingFacet for a fresh one whose
 *      `_vault.asset()` returns the given token. This is needed because
 *      `RewardsConfigFacet.setRewardsToken` was removed; `getRewardsToken()` now
 *      resolves to `_vault.asset()` if a vault is set, otherwise `_defaultToken`.
 *      The only way to point the rewards token at a custom token in tests is to
 *      replace the facet with one whose vault reports that token.
 */
abstract contract RewardsTokenHelper is LocalSetup {
    /**
     * @dev Replace the registered RewardsProcessingFacet with a fresh one whose
     *      vault.asset() returns `token`. Atomically swaps via
     *      `FacetRegistry.replaceFacet` so all 5 RewardsProcessingFacet selectors
     *      route to the new facet.
     */
    function _useTokenAsRewardsAsset(address token) internal {
        // Find the currently registered RewardsProcessingFacet by its selector
        address oldFacet = _facetRegistry.getFacetForSelector(RewardsProcessingFacet.processRewards.selector);

        // Mock vault that simply reports `token` as its underlying asset
        RewardsAssetShimVault mockVault = new RewardsAssetShimVault(token);

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        VotingEscrowRewardsProcessingFacet newFacet = new VotingEscrowRewardsProcessingFacet(
            address(_portfolioFactory),
            address(_swapConfig),
            address(_ve),
            address(mockVault),
            IVotingEscrow(_ve).token()
        );
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RewardsProcessingFacet.processRewards.selector;
        selectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        selectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        selectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        selectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _facetRegistry.replaceFacet(oldFacet, address(newFacet), selectors, "RewardsProcessingFacet");
        vm.stopPrank();
    }
}
