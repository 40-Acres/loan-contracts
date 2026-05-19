// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IHydrexVoter} from "../../../interfaces/IHydrexVoter.sol";
import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";
import {HydrexPortfolioFactoryConfig} from "./HydrexPortfolioFactoryConfig.sol";

/**
 * @title VeHydrexClaimingFacet
 * @dev Claim entry points for Hydrex.
 *      Rebase HYDX is automatically re-locked by Hydrex's RewardsDistributor:
 *      PERMANENT originals grow in-place via increaseAmount, ROLLING originals
 *      cause a fresh PERMANENT veNFT to be minted to the account. That mint
 *      routes through the receiver hook on the VE facet, which either assigns
 *      the bucket or merges into the existing bucket. This facet refreshes
 *      collateral tracking after the claim returns.
 */
contract VeHydrexClaimingFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    IHydrexVotingEscrow public immutable _votingEscrow;
    IHydrexVoter public immutable _voter;
    IRewardsDistributor public immutable _rewardsDistributor;

    event RebaseClaimed(uint256 indexed tokenId, uint256 amount);

    constructor(address portfolioFactory, address votingEscrow, address voter, address rewardsDistributor) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = IHydrexVotingEscrow(votingEscrow);
        _voter = IHydrexVoter(voter);
        _rewardsDistributor = IRewardsDistributor(rewardsDistributor);
    }

    /// @notice Claim pool fees and bribes for the account. The on-chain methods
    ///         claimFees and claimBribes are functionally identical on Hydrex (both
    ///         iterate the address list and call getReward); operators pass a mixed
    ///         list of internal_bribes and external_bribes contracts.
    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) public virtual {
        _voter.claimFees(fees, tokens, tokenId);
        claimRebase(tokenId);
    }

    function claimRebase(uint256 tokenId) public virtual {
        uint256 claimable = _rewardsDistributor.claimable(tokenId);
        if (claimable > 0) {
            _rewardsDistributor.claim(tokenId);
            emit RebaseClaimed(tokenId, claimable);
        }
        _updateLockedCollateral(tokenId);
        // Refresh the bucket separately if it's a distinct, account-owned token.
        // Stale-pointer guard: only refresh when the stored bucket is still owned by us.
        uint256 bucket = HydrexPortfolioFactoryConfig(address(_portfolioFactory.portfolioFactoryConfig()))
            .getRebaseTokenId(address(this));
        if (bucket != 0 && bucket != tokenId && _votingEscrow.ownerOf(bucket) == address(this)) {
            _updateLockedCollateral(bucket);
        }
    }

    function _updateLockedCollateral(uint256 tokenId) internal virtual {
        HydrexCollateralManager.updateLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }
}
