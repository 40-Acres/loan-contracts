// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {VotingEscrowRewardsProcessingFacet} from "./VotingEscrowRewardsProcessingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";

/**
 * @title DynamicRewardsProcessingFacet
 * @dev RewardsProcessingFacet variant for DynamicFeesVault — delegates to DynamicCollateralManager.
 */
contract DynamicRewardsProcessingFacet is VotingEscrowRewardsProcessingFacet {
    using SafeERC20 for IERC20;

    constructor(address portfolioFactory, address swapConfig, address votingEscrow, address vault, address collateralToken)
        VotingEscrowRewardsProcessingFacet(portfolioFactory, swapConfig, votingEscrow, vault, collateralToken) {}

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return DynamicCollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), amount);
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal override  returns (uint256 usedAmount) {
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        IVotingEscrow(address(_votingEscrow)).increaseAmount(tokenId, increaseAmount);
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        DynamicCollateralManager.updateLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow));
        emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
        return increaseAmount;
    }
}
