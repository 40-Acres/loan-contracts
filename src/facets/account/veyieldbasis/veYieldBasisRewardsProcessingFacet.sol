// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "../rewards_processing/RewardsProcessingFacet.sol";
import {IYieldBasisVotingEscrow} from "../../../interfaces/IYieldBasisVotingEscrow.sol";
import {veYieldBasisAdapter} from "../../../adapters/veYieldBasisAdapter.sol";
import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title veYieldBasisRewardsProcessingFacet
 * @dev Rewards processing facet adapted for YieldBasis's veYB.
 *
 * YieldBasis uses address-based locking (not tokenId-based like Aerodrome).
 * This facet overrides _increaseLock to call veYB.increase_amount()
 * directly instead of using the tokenId-based increaseAmount().
 */
contract veYieldBasisRewardsProcessingFacet is RewardsProcessingFacet {
    using SafeERC20 for IERC20;

    IYieldBasisVotingEscrow public immutable _veYB;
    veYieldBasisAdapter public immutable _veYBAdapter;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address veYB,
        address veYBAdapter,
        address vault
    ) RewardsProcessingFacet(
        portfolioFactory,
        swapConfig,
        veYieldBasisAdapter(veYBAdapter).token(), // Derive collateral token from adapter
        vault
    ) {
        require(veYB != address(0), "Invalid veYB");
        require(veYBAdapter != address(0), "Invalid veYB adapter");
        _veYB = IYieldBasisVotingEscrow(veYB);
        _veYBAdapter = veYieldBasisAdapter(veYBAdapter);
    }

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return DynamicCollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), amount);
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal override {
        IERC20(lockedAsset).approve(address(_veYB), increaseAmount);
        _veYB.increase_amount(increaseAmount);
        IERC20(lockedAsset).approve(address(_veYB), 0);
        DynamicCollateralManager.updateLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_veYBAdapter));
        emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
    }
}
