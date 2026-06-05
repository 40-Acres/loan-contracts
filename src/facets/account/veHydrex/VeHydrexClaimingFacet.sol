// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ClaimingFacet} from "../claim/ClaimingFacet.sol";
import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {IHydrexRewardsDistributor} from "../../../interfaces/IHydrexRewardsDistributor.sol";
import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";
import {HydrexPortfolioFactoryConfig} from "./HydrexPortfolioFactoryConfig.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// oHYDX option execution interface.
interface IOptionToken {
    function exerciseVe(uint256 _amount,address _recipient) external returns (uint256);
}

/**
 * @title VeHydrexClaimingFacet
 * @dev ClaimingFacet variant for Hydrex. Reuses the base `claimFees` path
 *      because Hydrex's Voter exposes `claimFees(addrs, tokens, tokenId)` with
 *      the same selector as the Velo/Aero IVoter. Overrides `claimRebase` to
 *      account for Hydrex's rebase semantics:
 *
 *        1. PERMANENT source: Hydrex's RewardsDistributor auto-applies the
 *           rebase in-place on the source lock. Plain claim() runs and the
 *           source's cached collateral is refreshed.
 *        2. Non-PERMANENT source with a valid rebase bucket: claimInto deposits
 *           the rebase value directly into the bucket lock with no new mint.
 *        3. Non-PERMANENT source with no bucket yet (first-time seed): Hydrex
 *           mints a fresh PERMANENT to this account via `_mint` (unsafe, so
 *           the receiver hook never fires). The mint is detected via an
 *           ERC721Enumerable walk between balance snapshots, the new id is
 *           set as the bucket, and tracked as collateral.
 *
 *      The external claim entry points are guarded by `nonReentrant`. The
 *      external `_rewardsDistributor` is set immutably at construction but is
 *      an upgradeable proxy in production -- the guard defends against future
 *      governance upgrades that could introduce malicious callbacks.
 */
contract VeHydrexClaimingFacet is ClaimingFacet, ReentrancyGuardTransient {
    IOptionToken constant public oHYDX = IOptionToken(0xA1136031150E50B015b41f1ca6B2e99e49D8cB78);
    address constant internal BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    event RebaseBucketAssigned(uint256 indexed tokenId, address indexed owner);

    error UnexpectedNewMint(uint256 expected, uint256 actual);

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
        _doExecuteOption();
        _doClaimRebase(tokenId);
    }

    function claimRebase(uint256 tokenId) public virtual override nonReentrant {
        _doClaimRebase(tokenId);
    }

    /// @notice Execute oHYDX option to create a new veNFT, and merge the new token
    function _doExecuteOption() internal {
        IHydrexVotingEscrow ve = IHydrexVotingEscrow(address(_votingEscrow));
        HydrexPortfolioFactoryConfig hConfig =
            HydrexPortfolioFactoryConfig(address(_portfolioFactory.portfolioFactoryConfig()));
        uint256 bucket = hConfig.getRebaseTokenId(address(this));
        bool bucketValid = bucket != 0 && ve.ownerOf(bucket) == address(this);

        uint256 oHYDXBalance = IERC20(address(oHYDX)).balanceOf(address(this));
        if (oHYDXBalance > 0 && bucketValid) {
            uint256 newVeNFTId = oHYDX.exerciseVe(oHYDXBalance, address(this));
            ve.merge(newVeNFTId, bucket);
            _updateLockedCollateral(bucket);
            // merge folds value into the bucket and leaves a zero-value source
            // lock. Only dispose of the husk once it holds no value, so a merge
            // that did not move everything can never burn value.
            if (ve.balanceOfNFT(newVeNFTId) == 0) {
                ve.safeTransferFrom(address(this), BURN_ADDRESS, newVeNFTId);
            }
        }
    }

    function _doClaimRebase(uint256 tokenId) internal {
        uint256 claimable = _rewardsDistributor.claimable(tokenId);
        if (claimable == 0) {
            _updateLockedCollateral(tokenId);
            return;
        }

        IHydrexVotingEscrow ve = IHydrexVotingEscrow(address(_votingEscrow));
        IHydrexRewardsDistributor distributor = IHydrexRewardsDistributor(address(_rewardsDistributor));
        IERC721Enumerable ve721 = IERC721Enumerable(address(_votingEscrow));

        IHydrexVotingEscrow.LockType sourceLockType = ve.lockDetails(tokenId).lockType;
        if (sourceLockType == IHydrexVotingEscrow.LockType.PERMANENT) {
            // Hydrex auto-applies the rebase in-place to the source lock. Sanity-check
            // that no new NFT was minted -- if Hydrex ever drifts here we want a loud
            // revert rather than a silently-orphaned NFT.
            uint256 balanceBefore = ve721.balanceOf(address(this));
            distributor.claim(tokenId);
            uint256 balanceAfter = ve721.balanceOf(address(this));
            if (balanceAfter != balanceBefore) revert UnexpectedNewMint(balanceBefore, balanceAfter);
            emit RebaseClaimed(tokenId, claimable);
            _updateLockedCollateral(tokenId);
            return;
        }

        HydrexPortfolioFactoryConfig hConfig =
            HydrexPortfolioFactoryConfig(address(_portfolioFactory.portfolioFactoryConfig()));
        uint256 bucket = hConfig.getRebaseTokenId(address(this));
        bool bucketValid = bucket != 0 && bucket != tokenId && ve.ownerOf(bucket) == address(this);

        if (bucketValid) {
            uint256 deposited = distributor.claimInto(tokenId, bucket);
            emit RebaseClaimed(tokenId, deposited);
            _updateLockedCollateral(bucket);
            _updateLockedCollateral(tokenId);
            return;
        }

        // First-time seed (or stale bucket pointer). Hydrex's claim() mints a fresh
        // PERMANENT via _mint (no receiver hook). Detect via balance snapshot, assert
        // exactly one new mint, designate as the bucket, and track as collateral.
        uint256 before = ve721.balanceOf(address(this));
        distributor.claim(tokenId);
        uint256 afterBal = ve721.balanceOf(address(this));
        if (afterBal != before + 1) revert UnexpectedNewMint(before + 1, afterBal);

        uint256 newId = ve721.tokenOfOwnerByIndex(address(this), before);
        hConfig.setRebaseTokenId(newId);
        _addLockedCollateralUnchecked(newId);

        emit RebaseClaimed(tokenId, claimable);
        emit RebaseBucketAssigned(newId, _portfolioFactory.ownerOf(address(this)));
        _updateLockedCollateral(tokenId);
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
