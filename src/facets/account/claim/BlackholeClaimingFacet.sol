// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ClaimingFacet} from "./ClaimingFacet.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";

/**
 * @title BlackholeClaimingFacet
 * @dev ClaimingFacet adapted for dual rewards distributors (Blackhole on Avalanche, SuperNova on Ethereum).
 *      Claims rebase from both a primary and secondary rewards distributor.
 */
contract BlackholeClaimingFacet is ClaimingFacet {
    IRewardsDistributor public immutable _secondaryRewardsDistributor;

    constructor(
        address portfolioFactory,
        address votingEscrow,
        address voter,
        address rewardsDistributor,
        address secondaryRewardsDistributor,
        address loanConfig,
        address swapConfig,
        address vault
    )
        ClaimingFacet(portfolioFactory, votingEscrow, voter, rewardsDistributor, loanConfig, swapConfig, vault)
    {
        require(secondaryRewardsDistributor != address(0));
        _secondaryRewardsDistributor = IRewardsDistributor(secondaryRewardsDistributor);
    }

    function claimRebase(uint256 tokenId) public override {
        _claimFromDistributor(_rewardsDistributor, tokenId);
        _claimFromDistributor(_secondaryRewardsDistributor, tokenId);
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
