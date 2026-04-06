// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {VotingEscrowRewardsProcessingFacet} from "./VotingEscrowRewardsProcessingFacet.sol";
import {IVotingEscrow} from "../../../Blackhole/interfaces/IVotingEscrow.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BlackholeRewardsProcessingFacet
 * @dev VotingEscrowRewardsProcessingFacet adapted for Blackhole's veBlack.
 *      Uses increase_amount() instead of increaseAmount().
 */
contract BlackholeRewardsProcessingFacet is VotingEscrowRewardsProcessingFacet {
    using SafeERC20 for IERC20;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address votingEscrow,
        address vault,
        address collateralToken
    ) VotingEscrowRewardsProcessingFacet(portfolioFactory, swapConfig, votingEscrow, vault, collateralToken) {}

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal override returns (uint256 usedAmount) {
        if (tokenId == 0) {
            return 0;
        }
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        try IVotingEscrow(address(_votingEscrow)).increase_amount(tokenId, increaseAmount) {
            CollateralManager.updateLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow));
            emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
        } catch {
            emit IncreaseCollateralFailed(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
            IERC20(lockedAsset).approve(address(_votingEscrow), 0);
            return 0;
        }
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        return increaseAmount;
    }
}
