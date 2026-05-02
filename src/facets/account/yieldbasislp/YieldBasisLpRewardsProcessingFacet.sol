// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "../rewards_processing/RewardsProcessingFacet.sol";
import {YieldBasisCollateralManager} from "./YieldBasisCollateralManager.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";

/**
 * @title YieldBasisLpRewardsProcessingFacet
 * @dev Rewards processing for YieldBasis LP portfolio accounts.
 *
 * Collateral is gauge shares (ERC4626). Emissions (YB tokens) are claimed
 * separately via YieldBasisLpClaimingFacet, swapped to USDC, then processed
 * here to repay debt or distribute to the user.
 */
contract YieldBasisLpRewardsProcessingFacet is RewardsProcessingFacet {

    address public immutable _gauge;
    address public immutable _lpToken;
    address public immutable _underlying;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address gauge,
        address vault,
        address defaultToken,
        address underlying
    ) RewardsProcessingFacet(
        portfolioFactory,
        swapConfig,
        IYieldBasisGauge(gauge).asset(), // LP token as underlyingLockedAsset — blocks selling it
        vault,
        defaultToken
    ) {
        require(gauge != address(0), "Invalid gauge");
        require(underlying != address(0), "Invalid underlying");
        _gauge = gauge;
        _lpToken = IYieldBasisGauge(gauge).asset();
        _underlying = underlying;
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return YieldBasisCollateralManager.getTotalDebt();
    }

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return YieldBasisCollateralManager.decreaseTotalDebt(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _lpToken,
            _underlying,
            amount
        );
    }

    function _getLoanUtilization() internal view override returns (uint256) {
        return YieldBasisCollateralManager.getLoanUtilization(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _lpToken,
            _underlying
        );
    }

    /// @dev Block swapping LP token (fungible collateral) and gauge shares
    function _isSwapAllowed(address inputToken) internal view override returns (bool) {
        return inputToken != _underlyingLockedAsset && inputToken != _gauge;
    }
}
