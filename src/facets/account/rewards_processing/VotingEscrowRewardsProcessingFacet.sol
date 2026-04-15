// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "./RewardsProcessingFacet.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UserRewardsConfig} from "./UserRewardsConfig.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SwapMod} from "../swap/SwapMod.sol";

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
        address underlyingLockedAsset
    ) RewardsProcessingFacet(
        portfolioFactory,
        swapConfig,
        underlyingLockedAsset,
        vault,
        underlyingLockedAsset
    ) {
        require(votingEscrow != address(0), "Invalid votingEscrow");
        _votingEscrow = IVotingEscrow(votingEscrow);
    }

    /// @dev Block swapping the veNFT token (e.g. veAERO). The underlying ERC20 (AERO)
    ///      is a legitimate fee reward and must remain swappable.
    function _isSwapAllowed(address inputToken) internal view virtual override returns (bool) {
        return inputToken != address(_votingEscrow);
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal virtual override returns (uint256 usedAmount) {
        if(tokenId == 0) {
            return 0;
        }
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        try IVotingEscrow(address(_votingEscrow)).increaseAmount(tokenId, increaseAmount) {
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

    function _increaseCollateral(uint256 tokenId, address rewardsToken, uint256 optionAmount, SwapMod.RouteParams memory swapParams) internal override returns (uint256 amountUsed) {
        if (tokenId == 0) {
            return 0;
        }
        return super._increaseCollateral(tokenId, rewardsToken, optionAmount, swapParams);
    }

    function _routeForDistributionEntry(
        UserRewardsConfig.DistributionEntry memory entry, uint256 amount,
        address asset, address lockedAsset, uint256 tokenId
    ) internal view override returns (SwapRoute memory route) {
        if(tokenId == 0 && entry.option == UserRewardsConfig.RewardsOption.IncreaseCollateral)  {
                return SwapRoute(address(0), address(0), 0);
        }
        return super._routeForDistributionEntry(entry, amount, asset, lockedAsset, tokenId);
    }
}
