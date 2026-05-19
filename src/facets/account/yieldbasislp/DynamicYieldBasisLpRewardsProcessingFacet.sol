// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "../rewards_processing/RewardsProcessingFacet.sol";
import {DynamicYieldBasisCollateralManager} from "./DynamicYieldBasisCollateralManager.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";

/**
 * @title DynamicYieldBasisLpRewardsProcessingFacet
 * @dev Rewards processing for YB LP portfolio accounts on a live-debt-read
 *      vault. Emissions claimed via DynamicYieldBasisLpClaimingFacet, swapped
 *      to the lending asset, then processed here against per-borrower debt.
 */
contract DynamicYieldBasisLpRewardsProcessingFacet is RewardsProcessingFacet {

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
        IYieldBasisGauge(gauge).asset(), // LP token as underlyingLockedAsset
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
        return DynamicYieldBasisCollateralManager.getTotalDebt(
            address(_portfolioFactory.portfolioFactoryConfig())
        );
    }

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return DynamicYieldBasisCollateralManager.decreaseTotalDebt(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _lpToken,
            _underlying,
            amount
        );
    }

    function _getLoanUtilization() internal view override returns (uint256) {
        return DynamicYieldBasisCollateralManager.getLoanUtilization(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _lpToken,
            _underlying
        );
    }

    function _isSwapAllowed(address inputToken) internal view override returns (bool) {
        return inputToken != _underlyingLockedAsset && inputToken != _gauge;
    }
}
