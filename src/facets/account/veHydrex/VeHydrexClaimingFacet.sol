// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ClaimingFacet} from "../claim/ClaimingFacet.sol";
import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";
import {HydrexPortfolioFactoryConfig} from "./HydrexPortfolioFactoryConfig.sol";
import {HydrexBucketLib} from "./HydrexBucketLib.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title VeHydrexClaimingFacet
 * @dev ClaimingFacet variant for Hydrex. Reuses the base `claimFees` path
 *      because Hydrex's Voter exposes `claimFees(addrs, tokens, tokenId)` with
 *      the same selector as the Velo/Aero IVoter. Overrides `claimRebase` to
 *      account for Hydrex's rebase semantics: non-PERMANENT originals route a
 *      fresh PERMANENT veNFT through this facet, NOT through the VE facet's
 *      receiver hook -- Hydrex's `_createLock` uses `_mint` (unsafe), so the
 *      ERC721 receiver callback never fires. We detect the new mint by
 *      walking the account's `IERC721Enumerable` entries between snapshots.
 *
 *      The external claim entry points are guarded by `nonReentrant`. The
 *      external `_rewardsDistributor` is set immutably at construction but is
 *      an upgradeable proxy in production -- the guard defends against future
 *      governance upgrades that could introduce malicious callbacks.
 */
contract VeHydrexClaimingFacet is ClaimingFacet, ReentrancyGuardTransient {
    event RebaseBucketAssigned(uint256 indexed tokenId, address indexed owner);
    event RebaseBucketAbsorbed(uint256 indexed from, uint256 indexed to, address indexed owner);

    constructor(address portfolioFactory, address votingEscrow, address voter, address rewardsDistributor)
        ClaimingFacet(portfolioFactory, votingEscrow, voter, rewardsDistributor, address(0), address(0), address(0))
    {}

    /// @notice Claim fees + rebase. Guarded by nonReentrant; delegates to internal
    ///         helpers so the public-to-public self-call to claimRebase does not
    ///         attempt to re-acquire the transient guard.
    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId)
        public
        override
        nonReentrant
    {
        _claimFees(fees, tokens, tokenId);
        _doClaimRebase(tokenId);
    }

    function claimRebase(uint256 tokenId) public virtual override nonReentrant {
        _doClaimRebase(tokenId);
    }

    function _doClaimRebase(uint256 tokenId) internal {
        uint256 claimable = _rewardsDistributor.claimable(tokenId);
        if (claimable > 0) {
            IERC721Enumerable ve721 = IERC721Enumerable(address(_votingEscrow));
            uint256 balanceBefore = ve721.balanceOf(address(this));
            _rewardsDistributor.claim(tokenId);
            emit RebaseClaimed(tokenId, claimable);
            uint256 balanceAfter = ve721.balanceOf(address(this));

            // Hydrex's RewardsDistributor uses `_mint` (unsafe) when minting a fresh
            // PERMANENT for non-PERMANENT originals. The receiver hook does NOT fire
            // for that path. Detect the new mint via per-owner ERC721Enumerable walk
            // (O(1) per index lookup; attacker mints to OTHER addresses don't bump our
            // balanceOf, so this is DoS-safe).
            for (uint256 i = balanceBefore; i < balanceAfter; i++) {
                uint256 newId = ve721.tokenOfOwnerByIndex(address(this), i);
                _routeIncomingPermanent(newId);
            }
        }
        _updateLockedCollateral(tokenId);

        uint256 bucket = HydrexPortfolioFactoryConfig(address(_portfolioFactory.portfolioFactoryConfig()))
            .getRebaseTokenId(address(this));
        if (
            bucket != 0 && bucket != tokenId
                && IHydrexVotingEscrow(address(_votingEscrow)).ownerOf(bucket) == address(this)
        ) {
            _updateLockedCollateral(bucket);
        }
    }

    function _routeIncomingPermanent(uint256 incomingTokenId) internal {
        (uint256 trackId, uint256 updateId) = HydrexBucketLib.absorbMint(
            address(_portfolioFactory.portfolioFactoryConfig()), address(_votingEscrow), incomingTokenId
        );
        address owner = _portfolioFactory.ownerOf(address(this));
        if (trackId != 0) {
            _addLockedCollateralUnchecked(trackId);
            emit RebaseBucketAssigned(trackId, owner);
        } else {
            _updateLockedCollateral(updateId);
            emit RebaseBucketAbsorbed(incomingTokenId, updateId, owner);
        }
    }

    function _updateLockedCollateral(uint256 tokenId) internal virtual override {
        HydrexCollateralManager.updateLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _addLockedCollateralUnchecked(uint256 tokenId) internal virtual {
        HydrexCollateralManager.addLockedCollateralUnchecked(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _getTotalDebt() internal view virtual override returns (uint256) {
        return HydrexCollateralManager.getTotalDebt();
    }

    function _decreaseTotalDebt(uint256 amount) internal virtual override returns (uint256 excess) {
        return HydrexCollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), amount);
    }
}
