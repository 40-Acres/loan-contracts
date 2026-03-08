// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {AccessControl} from "../utils/AccessControl.sol";

/**
 * @title YieldBasisLpClaimingFacet
 * @dev Claims YB token rewards from a YieldBasis gauge.
 * Rewards are left on the portfolio account contract for further processing
 * (e.g. by RewardsProcessingFacet).
 */
contract YieldBasisLpClaimingFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;

    event GaugeRewardsClaimed(address indexed reward, uint256 amount);

    constructor(address portfolioFactory, address gauge) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
    }

    /**
     * @notice Claim reward tokens from the YieldBasis gauge
     * @param reward The reward token to claim (e.g. YB token address)
     * @return claimed Amount of reward tokens claimed
     */
    function claimGaugeRewards(address reward) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 claimed) {
        claimed = _gauge.claim(reward, address(this));
        emit GaugeRewardsClaimed(reward, claimed);
    }

    /**
     * @notice Preview claimable reward tokens from the gauge
     * @param reward The reward token to query
     * @return Amount of reward tokens claimable
     */
    function previewGaugeRewards(address reward) external view returns (uint256) {
        return _gauge.preview_claim(reward, address(this));
    }
}
