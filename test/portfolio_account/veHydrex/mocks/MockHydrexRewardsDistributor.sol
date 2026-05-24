// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {IHydrexRewardsDistributor} from "../../../../src/interfaces/IHydrexRewardsDistributor.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IHydrexVotingEscrow} from "../../../../src/interfaces/IHydrexVotingEscrow.sol";
import {MockHydrexVotingEscrow} from "./MockHydrexVotingEscrow.sol";

/// @notice Minimal mock of Hydrex RewardsDistributor.
///
///         Two behaviours simulated:
///           - "perma mode": claim() routes via VE.increaseAmount on the same token
///             (real Hydrex behaviour when the token is PERMANENT)
///           - "mint mode": claim() mints a new PERMANENT veNFT to the owner via
///             VE.mintAndSend, simulating non-PERMANENT rebase emission flow.
contract MockHydrexRewardsDistributor is IHydrexRewardsDistributor {
    MockHydrexVotingEscrow internal _ve;

    mapping(uint256 => uint256) public claimableAmount;
    mapping(uint256 => address) public ownerOverride;

    bool public mintMode; // false => use increaseAmount, true => mintAndSend
    uint256 public mintsPerClaim = 1; // how many fresh NFTs claim() mints when mintMode

    constructor(address veAddr) {
        _ve = MockHydrexVotingEscrow(veAddr);
    }

    function setClaimable(uint256 tokenId, uint256 amount) external { claimableAmount[tokenId] = amount; }
    function setMintMode(bool b) external { mintMode = b; }

    /// @notice Test knob: in mintMode, mint N fresh PERMANENT NFTs per claim()
    ///         instead of the default one. The facet's claim path snapshot
    ///         (balanceBefore + 1 == balanceAfter) is meant to detect drift here;
    ///         setting N != 1 should trigger the UnexpectedNewMint revert.
    function setMintsPerClaim(uint256 n) external { mintsPerClaim = n; }

    function WEEK() external pure returns (uint256) { return 7 days; }
    function startTime() external pure returns (uint256) { return 0; }
    function timeCursorOf(uint256) external pure returns (uint256) { return 0; }
    function lastTokenTime() external pure returns (uint256) { return 0; }
    function ve() external view returns (IVotingEscrow) { return IVotingEscrow(address(_ve)); }
    function token() external view returns (address) { return _ve.token(); }
    function minter() external pure returns (address) { return address(0); }
    function tokenLastBalance() external pure returns (uint256) { return 0; }
    function checkpointToken() external {}

    function claimable(uint256 tokenId) external view returns (uint256) { return claimableAmount[tokenId]; }

    function claim(uint256 tokenId) external returns (uint256) {
        uint256 amount = claimableAmount[tokenId];
        if (amount == 0) return 0;
        address owner = _ve.ownerOf(tokenId);

        if (mintMode) {
            // Non-PERMANENT path: mint N new PERMANENT veNFTs via the unsafe `_mint`
            // semantics that the real Hydrex VE uses (no receiver-hook callback).
            // Default N == 1 preserves single-mint behaviour; tests can crank to
            // exercise the facet's balanceAfter-balanceBefore sanity check.
            uint256 n = mintsPerClaim;
            for (uint256 i = 0; i < n; i++) {
                _ve.mintTo(owner, amount, IHydrexVotingEscrow.LockType.PERMANENT);
            }
        } else {
            // PERMANENT-in-place: simulate VE.increaseAmount on this same token without
            // pulling funds (the real RewardsDistributor holds the rebase asset).
            uint256 prev = _ve.lockDetails(tokenId).amount;
            _ve.setLockAmount(tokenId, prev + amount);
        }
        claimableAmount[tokenId] = 0;
        return amount;
    }

    function claimMany(uint256[] calldata) external pure returns (bool) { return false; }
    function setMinter(address) external {}

    /// @notice Mirrors Hydrex's claimInto: deposit `tokenId`'s claimable into
    ///         `receiverTokenId` without minting a new NFT.
    function claimInto(uint256 tokenId, uint256 receiverTokenId) external returns (uint256) {
        uint256 amount = claimableAmount[tokenId];
        if (amount == 0) return 0;
        require(_ve.ownerOf(receiverTokenId) != address(0), "no receiver");
        uint256 prev = _ve.lockDetails(receiverTokenId).amount;
        _ve.setLockAmount(receiverTokenId, prev + amount);
        claimableAmount[tokenId] = 0;
        return amount;
    }
}
