// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {HydrexPortfolioFactoryConfig} from "./HydrexPortfolioFactoryConfig.sol";

/**
 * @title HydrexBucketLib
 * @dev Shared rebase-bucket logic for incoming PERMANENT veNFTs. Two entry
 *      points need this:
 *        1. `VeHydrexVotingEscrowFacet.onERC721Received`, when a user
 *           safeTransferFrom's an external PERMANENT veNFT into the account.
 *        2. `VeHydrexClaimingFacet.claimRebase`, when Hydrex's
 *           RewardsDistributor mints a fresh PERMANENT veNFT for a
 *           non-PERMANENT original. Hydrex's `_createLock` uses `_mint`
 *           (unsafe), so the receiver hook does NOT fire on that path; the
 *           claim facet must detect the new mint itself and call into this lib.
 *
 *      The library handles the bucket-pointer update and the merge call.
 *      The caller is responsible for the collateral-tracking step using the
 *      returned ids: `trackId` (set-as-bucket path, needs add) or `updateId`
 *      (merge-into-existing-bucket path, needs update).
 */
library HydrexBucketLib {
    /// @notice Route a freshly-arrived PERMANENT veNFT through the bucket lifecycle.
    /// @return trackId Non-zero if the incoming token is now the bucket (caller must add as collateral).
    /// @return updateId Non-zero if the incoming was merged into an existing bucket (caller must refresh).
    /// @dev Exactly one of trackId / updateId is non-zero on return. Stale bucket
    ///      pointers (transferred out of the account) are auto-reset to the incoming.
    function absorbMint(address config, address ve, uint256 incomingTokenId)
        internal
        returns (uint256 trackId, uint256 updateId)
    {
        HydrexPortfolioFactoryConfig hConfig = HydrexPortfolioFactoryConfig(config);
        IHydrexVotingEscrow hve = IHydrexVotingEscrow(ve);

        uint256 bucket = hConfig.getRebaseTokenId(address(this));
        bool bucketValid =
            bucket != 0 && bucket != incomingTokenId && hve.ownerOf(bucket) == address(this);

        if (!bucketValid) {
            hConfig.setRebaseTokenId(incomingTokenId);
            trackId = incomingTokenId;
        } else {
            hve.merge(incomingTokenId, bucket);
            updateId = bucket;
        }
    }
}
