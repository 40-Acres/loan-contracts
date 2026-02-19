// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {RewardsProcessingFacet} from "./RewardsProcessingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";

/**
 * @title DynamicRewardsProcessingFacet
 * @dev RewardsProcessingFacet variant for DynamicFeesVault — delegates to DynamicCollateralManager.
 */
contract DynamicRewardsProcessingFacet is RewardsProcessingFacet {
    using SafeERC20 for IERC20;

    constructor(address portfolioFactory, address portfolioAccountConfig, address swapConfig, address votingEscrow, address vault)
        RewardsProcessingFacet(portfolioFactory, portfolioAccountConfig, swapConfig, votingEscrow, vault) {}

    function _processActiveLoanRewards(uint256 tokenId, uint256 availableAmount, address asset) internal override returns (uint256 remaining) {
        require(IERC20(asset).balanceOf(address(this)) >= availableAmount);
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));

        uint256 excess = DynamicCollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), availableAmount);
        emit LoanPaid(_currentEpochStart(), tokenId, availableAmount, _portfolioFactory.ownerOf(address(this)), address(asset));

        return excess;
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal override {
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        IVotingEscrow(address(_votingEscrow)).increaseAmount(tokenId, increaseAmount);
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        DynamicCollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
        emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
    }
}
