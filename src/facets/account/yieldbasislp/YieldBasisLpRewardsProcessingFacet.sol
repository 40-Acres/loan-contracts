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
 * - _underlyingLockedAsset set to LP token to prevent selling collateral
 * - _increaseLock is a no-op (base default) — no veNFT lock to compound into
 */
contract YieldBasisLpRewardsProcessingFacet is RewardsProcessingFacet {

    address public immutable _gauge;
    address public immutable _lpToken;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address gauge,
        address vault,
        address defaultToken
    ) RewardsProcessingFacet(
        portfolioFactory,
        swapConfig,
        IYieldBasisGauge(gauge).asset(), // LP token as underlyingLockedAsset — blocks selling it
        vault,
        defaultToken
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

    function _getLTVRatio() internal view override returns (uint256) {
        return ERC4626CollateralManager.getLTVRatio(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _gauge,
            _lpToken
        );
    }

    /// @dev Block swapping LP token (fungible collateral) and gauge shares
    function _isSwapAllowed(address inputToken) internal view override returns (bool) {
        return inputToken != _underlyingLockedAsset && inputToken != _gauge;
    }
}
