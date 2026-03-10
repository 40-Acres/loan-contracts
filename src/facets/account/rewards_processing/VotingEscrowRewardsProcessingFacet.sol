// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "./RewardsProcessingFacet.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VotingEscrowRewardsProcessingFacet
 * @dev RewardsProcessingFacet variant for veNFT-based collateral.
 * Adds VotingEscrow-specific _increaseLock logic.
 */
contract VotingEscrowRewardsProcessingFacet is RewardsProcessingFacet {
    using SafeERC20 for IERC20;

    IVotingEscrow public immutable _votingEscrow;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address votingEscrow,
        address vault,
        address collateralToken
    ) RewardsProcessingFacet(
        portfolioFactory,
        swapConfig,
        collateralToken,
        vault
    ) {
        require(votingEscrow != address(0), "Invalid votingEscrow");
        _votingEscrow = IVotingEscrow(votingEscrow);
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal virtual override {
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        IVotingEscrow(address(_votingEscrow)).increaseAmount(tokenId, increaseAmount);
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        CollateralManager.updateLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow));
        emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
    }
}
