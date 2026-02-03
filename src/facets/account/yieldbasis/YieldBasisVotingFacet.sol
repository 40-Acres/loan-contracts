// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IYieldBasisVotingEscrow} from "../../../interfaces/IYieldBasisVotingEscrow.sol";
import {IYieldBasisGaugeController} from "../../../interfaces/IYieldBasisGaugeController.sol";
import {IYieldBasisFeeDistributor} from "../../../interfaces/IYieldBasisFeeDistributor.sol";
import {AccessControl} from "../utils/AccessControl.sol";

/**
 * @title YieldBasisVotingFacet
 * @dev Facet for voting on YieldBasis gauge weights (Ethereum)
 *
 * veYB holders vote to direct YB emissions to liquidity gauges.
 * Voting power is based on veYB balance.
 * 10-day cooldown between vote changes per gauge.
 * Weights are expressed in bps (0-10000, where 10000 = 100%).
 *
 * Locks are infinite (via infinite_lock_toggle) so no lock extension needed.
 *
 * Contract Addresses (Ethereum Mainnet):
 * - veYB: 0x8235c179E9e84688FBd8B12295EfC26834dAC211
 * - GaugeController: 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21
 */
contract YieldBasisVotingFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IYieldBasisVotingEscrow public immutable _veYB;
    IYieldBasisGaugeController public immutable _gaugeController;
    IYieldBasisFeeDistributor public immutable _feeDistributor;

    uint256 public constant MAX_WEIGHT = 10000; // 100% in bps
    uint256 public constant VOTE_COOLDOWN = 15 days; // if user hasnt voted in 15 days, they will be in automatic voting mode

    error NoVotingPower();
    error InvalidWeight();

    constructor(
        address portfolioFactory,
        address portfolioAccountConfig,
        address veYB,
        address gaugeController,
        address feeDistributor
    ) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(portfolioAccountConfig != address(0), "Invalid config");
        require(veYB != address(0), "Invalid veYB");
        require(gaugeController != address(0), "Invalid gauge controller");
        require(feeDistributor != address(0), "Invalid fee distributor");

        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _veYB = IYieldBasisVotingEscrow(veYB);
        _gaugeController = IYieldBasisGaugeController(gaugeController);
        _feeDistributor = IYieldBasisFeeDistributor(feeDistributor);
    }


    /**
     * @notice Vote for multiple gauges with specified weights
     * @param gauges Array of gauge addresses
     * @param weights Array of weights in bps (must sum to <= 10000)
     */
    function vote(
        address[] calldata gauges,
        uint256[] calldata weights
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        _gaugeController.vote_for_gauge_weights(gauges, weights);
    }


    function defaultVote(
        address[] calldata gauges,
        uint256[] calldata weights
    ) external onlyAuthorizedCaller(_portfolioFactory) {
        require(gauges.length == weights.length, "Length mismatch");
        require(gauges.length > 0, "Empty arrays");

        // Validate total weight doesn't exceed 100%
        uint256 totalWeight;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
            uint256 lastVote = _gaugeController.last_user_vote(address(this), gauges[i]);
            require(block.timestamp - lastVote >= VOTE_COOLDOWN, "Voting cooldown not met");
        }
        require(totalWeight == MAX_WEIGHT, InvalidWeight());
        _gaugeController.vote_for_gauge_weights(gauges, weights);
    }
}
