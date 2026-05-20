// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicHydrexCollateralManager} from "./DynamicHydrexCollateralManager.sol";
import {VotingEscrowRewardsProcessingFacet} from "../rewards_processing/VotingEscrowRewardsProcessingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";

/**
 * @title DynamicHydrexRewardsProcessingFacet
 * @dev RewardsProcessingFacet variant paired with DynamicFeesVault-backed debt and
 *      Hydrex veHYDX collateral. The base facet types its escrow handle as
 *      IVotingEscrow but only calls increaseAmount(tokenId, value), whose
 *      selector matches IHydrexVotingEscrow exactly.
 */
contract DynamicHydrexRewardsProcessingFacet is VotingEscrowRewardsProcessingFacet {
    using SafeERC20 for IERC20;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address votingEscrow,
        address vault,
        address underlyingLockedAsset,
        address defaultToken
    )
        VotingEscrowRewardsProcessingFacet(
            portfolioFactory,
            swapConfig,
            votingEscrow,
            vault,
            underlyingLockedAsset,
            defaultToken
        )
    {}

    function _getTotalDebt() internal view override returns (uint256) {
        return DynamicHydrexCollateralManager.getTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return DynamicHydrexCollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), amount);
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount_, address lockedAsset)
        internal
        override
        returns (uint256 usedAmount)
    {
        if (tokenId == 0) return 0;
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount_);
        try IHydrexVotingEscrow(address(_votingEscrow)).increaseAmount(tokenId, increaseAmount_) {
            DynamicHydrexCollateralManager.updateLockedCollateral(
                address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
            );
            emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount_, _portfolioFactory.ownerOf(address(this)));
        } catch {
            emit IncreaseCollateralFailed(_currentEpochStart(), tokenId, increaseAmount_, _portfolioFactory.ownerOf(address(this)));
            IERC20(lockedAsset).approve(address(_votingEscrow), 0);
            return 0;
        }
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        return increaseAmount_;
    }
}
