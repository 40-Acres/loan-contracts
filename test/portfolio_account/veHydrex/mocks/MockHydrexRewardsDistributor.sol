// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
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
contract MockHydrexRewardsDistributor is IRewardsDistributor {
    MockHydrexVotingEscrow internal _ve;

    mapping(uint256 => uint256) public claimableAmount;
    mapping(uint256 => address) public ownerOverride;

    bool public mintMode; // false => use increaseAmount, true => mintAndSend

    constructor(address veAddr) {
        _ve = MockHydrexVotingEscrow(veAddr);
    }

    function setClaimable(uint256 tokenId, uint256 amount) external { claimableAmount[tokenId] = amount; }
    function setMintMode(bool b) external { mintMode = b; }

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
            // Non-PERMANENT path: mint a new PERMANENT veNFT via the unsafe `_mint`
            // semantics that the real Hydrex VE uses (no receiver-hook callback).
            _ve.mintTo(owner, amount, IHydrexVotingEscrow.LockType.PERMANENT);
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
}
