// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "../rewards_processing/RewardsProcessingFacet.sol";
import {ERC4626CollateralManager} from "../erc4626/ERC4626CollateralManager.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";

/**
 * @title YieldBasisLpRewardsProcessingFacet
 * @dev Rewards processing for YieldBasis LP portfolio accounts.
 *
 * Collateral is gauge shares (ERC4626). Emissions (YB tokens) are claimed
 * separately via YieldBasisLpClaimingFacet, swapped to USDC, then processed
 * here to repay debt or distribute to the user.
 *
 * Key difference from veNFT variants:
 * - Debt tracked via ERC4626CollateralManager (not CollateralManager/DynamicCollateralManager)
 * - _collateralToken set to LP token to prevent selling collateral
 * - _increaseLock is a no-op (base default) — no veNFT lock to compound into
 */
contract YieldBasisLpRewardsProcessingFacet is RewardsProcessingFacet {

    address public immutable _gauge;
    address public immutable _lpToken;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address gauge,
        address vault
    ) RewardsProcessingFacet(
        portfolioFactory,
        swapConfig,
        IYieldBasisGauge(gauge).asset(), // LP token as collateralToken — blocks selling it
        vault
    ) {
        require(gauge != address(0), "Invalid gauge");
        _gauge = gauge;
        _lpToken = IYieldBasisGauge(gauge).asset();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return ERC4626CollateralManager.getTotalDebt();
    }

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return ERC4626CollateralManager.decreaseTotalDebt(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _gauge,
            _lpToken,
            amount
        );
    }

    /// @dev Block swapping gauge shares in addition to LP token (already blocked by base)
    function _validateSwapInput(address inputToken) internal view override {
        super._validateSwapInput(inputToken);
        require(inputToken != _gauge, "Input token cannot be gauge token");
    }
}
