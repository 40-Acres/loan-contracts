// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "../rewards_processing/RewardsProcessingFacet.sol";
import {IYieldBasisVotingEscrow} from "../../../interfaces/IYieldBasisVotingEscrow.sol";
import {YieldBasisVotingEscrowAdapter} from "../../../adapters/YieldBasisVotingEscrowAdapter.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {SwapMod} from "../swap/SwapMod.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldBasisRewardsProcessingFacet
 * @dev Rewards processing facet adapted for YieldBasis's veYB.
 *
 * YieldBasis uses address-based locking (not tokenId-based like Aerodrome).
 * This facet overrides _increaseCollateral to call veYB.increase_amount()
 * directly instead of using the tokenId-based increaseAmount().
 */
contract YieldBasisRewardsProcessingFacet is RewardsProcessingFacet {
    using SafeERC20 for IERC20;

    IYieldBasisVotingEscrow public immutable _veYB;
    YieldBasisVotingEscrowAdapter public immutable _veYBAdapter;

    constructor(
        address portfolioFactory,
        address portfolioAccountConfig,
        address swapConfig,
        address veYB,
        address veYBAdapter,
        address vault
    ) RewardsProcessingFacet(
        portfolioFactory,
        portfolioAccountConfig,
        swapConfig,
        veYBAdapter, // Pass adapter as votingEscrow for token() calls
        vault
    ) {
        require(veYB != address(0), "Invalid veYB");
        require(veYBAdapter != address(0), "Invalid veYB adapter");
        _veYB = IYieldBasisVotingEscrow(veYB);
        _veYBAdapter = YieldBasisVotingEscrowAdapter(veYBAdapter);
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal override {
        IERC20(lockedAsset).approve(address(_veYB), increaseAmount);
        _veYB.increase_amount(increaseAmount);
        IERC20(lockedAsset).approve(address(_veYB), 0);
        CollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_veYBAdapter));
        emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
    }
}
