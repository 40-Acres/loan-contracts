// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";

interface IBlackholeLoan {
    function claimRebase(uint256 tokenId) external;
}

/// @title BlackholeRebaseHelper
/// @notice Deploy once. Call scan() off-chain to find claimable tokens,
///         then claim(tokenIds) to batch-claim them.
contract BlackholeRebaseHelper {
    address public constant BLACKHOLE_LOAN = 0x5122f5154DF20E5F29df53E633cE1ac5b6623558;
    IVotingEscrow public constant VE = IVotingEscrow(0xEac562811cc6abDbB2c9EE88719eCA4eE79Ad763);
    address public constant REWARDS_DISTRIBUTOR_1 = 0x88a49cFCee0Ed5B176073DDE12186C4c922A9cD0;
    address public constant REWARDS_DISTRIBUTOR_2 = 0x7c7BD86BaF240dB3DbCc3f7a22B35c5bAa83bA28;

    /// @notice Scan from `startIndex` and return up to `maxResults` token IDs that have claimable rebase.
    function scan(uint256 startIndex, uint256 maxResults) external view returns (uint256[] memory tokenIds) {
        uint256 nftCount = VE.balanceOf(BLACKHOLE_LOAN);
        if (nftCount == 0 || startIndex >= nftCount) return new uint256[](0);

        uint256[] memory tmp = new uint256[](maxResults);
        uint256 found;

        for (uint256 i = startIndex; i < nftCount && found < maxResults; i++) {
            uint256 tokenId = VE.tokenOfOwnerByIndex(BLACKHOLE_LOAN, i);
            if (_hasClaimable(tokenId)) {
                tmp[found] = tokenId;
                found++;
            }
        }

        tokenIds = new uint256[](found);
        for (uint256 i = 0; i < found; i++) {
            tokenIds[i] = tmp[i];
        }
    }

    /// @notice Claim rebase for the given token IDs in one transaction.
    function claim(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            IBlackholeLoan(BLACKHOLE_LOAN).claimRebase(tokenIds[i]);
        }
    }

    function _hasClaimable(uint256 tokenId) internal view returns (bool) {
        try IRewardsDistributor(REWARDS_DISTRIBUTOR_1).claimable(tokenId) returns (uint256 c) {
            if (c > 0) return true;
        } catch {}
        try IRewardsDistributor(REWARDS_DISTRIBUTOR_2).claimable(tokenId) returns (uint256 c) {
            if (c > 0) return true;
        } catch {}
        return false;
    }
}
