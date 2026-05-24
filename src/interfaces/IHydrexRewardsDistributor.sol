// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRewardsDistributor} from "./IRewardsDistributor.sol";

/// @title IHydrexRewardsDistributor
/// @notice Hydrex-specific extension of IRewardsDistributor. Adds claimInto,
///         which deposits a token's claimable rebase directly into an existing
///         PERMANENT lock with no new NFT minted.
interface IHydrexRewardsDistributor is IRewardsDistributor {
    /// @notice Claim rebases for `tokenId` and deposit them into `receiverTokenId`.
    /// @dev    `receiverTokenId` must be a PERMANENT lock owned by msg.sender.
    /// @return amount The amount of rebases claimed and deposited.
    function claimInto(uint256 tokenId, uint256 receiverTokenId) external returns (uint256 amount);
}
