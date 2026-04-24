// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ClaimingFacet} from "../claim/ClaimingFacet.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {IGaugeManager} from "../../../Blackhole/interfaces/IGaugeManager.sol";

/**
 * @title BlackholeClaimingFacet
 * @dev ClaimingFacet adapted for Blackhole-style deployments 
 */
contract BlackholeClaimingFacet is ClaimingFacet {
    IRewardsDistributor public immutable _secondaryRewardsDistributor;
    IGaugeManager public immutable _gaugeManager;

    constructor(
        address portfolioFactory,
        address votingEscrow,
        address voter,
        address gaugeManager,
        address rewardsDistributor,
        address secondaryRewardsDistributor,
        address loanConfig,
        address swapConfig,
        address vault
    )
        ClaimingFacet(portfolioFactory, votingEscrow, voter, rewardsDistributor, loanConfig, swapConfig, vault)
    {
        require(gaugeManager != address(0));
        _gaugeManager = IGaugeManager(gaugeManager);
        // secondary rewards distributor is optional (Blackhole/Avax has two, SuperNova/Ethereum has one)
        _secondaryRewardsDistributor = IRewardsDistributor(secondaryRewardsDistributor);
    }

    function _claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) internal override {
        _gaugeManager.claimBribes(fees, tokens, tokenId);
    }

    function claimRebase(uint256 tokenId) public override {
        _claimFromDistributor(_rewardsDistributor, tokenId);
        if (address(_secondaryRewardsDistributor) != address(0)) {
            _claimFromDistributor(_secondaryRewardsDistributor, tokenId);
        }
        _updateLockedCollateral(tokenId);
    }

    function _claimFromDistributor(IRewardsDistributor distributor, uint256 tokenId) internal {
        uint256 claimable = distributor.claimable(tokenId);
        if (claimable > 0) {
            try distributor.claim(tokenId) {
                emit RebaseClaimed(tokenId, claimable);
            } catch {}
        }
    }
}
