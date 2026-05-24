// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {IHydrexRewardsDistributor} from "../../../../src/interfaces/IHydrexRewardsDistributor.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";

interface IClaimRebase {
    function claimRebase(uint256 tokenId) external;
}

/// @notice Adversarial Hydrex RewardsDistributor mock that tries to re-enter
///         the diamond's claimRebase entry point synchronously on every claim
///         path. Used to validate the nonReentrant guard on the claiming facet.
///
///         The contract is reusable across both PERMANENT (claim) and ROLLING
///         (claimInto + claim) paths: every call site re-enters by invoking
///         claimRebase(reentryTokenId) on the configured target before
///         returning. The guard must reject.
contract MockReentrantHydrexDistributor is IHydrexRewardsDistributor {
    address public _ve;
    address public target;        // diamond / portfolio account
    uint256 public reentryTokenId; // tokenId to re-enter with

    mapping(uint256 => uint256) public claimableAmount;

    constructor(address veAddr) {
        _ve = veAddr;
    }

    function setTarget(address t, uint256 tokenId) external {
        target = t;
        reentryTokenId = tokenId;
    }

    function setClaimable(uint256 tokenId, uint256 amount) external { claimableAmount[tokenId] = amount; }

    function WEEK() external pure returns (uint256) { return 7 days; }
    function startTime() external pure returns (uint256) { return 0; }
    function timeCursorOf(uint256) external pure returns (uint256) { return 0; }
    function lastTokenTime() external pure returns (uint256) { return 0; }
    function ve() external view returns (IVotingEscrow) { return IVotingEscrow(_ve); }
    function token() external pure returns (address) { return address(0); }
    function minter() external pure returns (address) { return address(0); }
    function tokenLastBalance() external pure returns (uint256) { return 0; }
    function checkpointToken() external {}
    function claimMany(uint256[] calldata) external pure returns (bool) { return false; }
    function setMinter(address) external {}

    function claimable(uint256 tokenId) external view returns (uint256) { return claimableAmount[tokenId]; }

    function claim(uint256) external returns (uint256) {
        // Re-enter the diamond's claimRebase while the outer nonReentrant guard
        // is still set. The expected outcome is ReentrancyGuardReentrantCall.
        if (target != address(0)) {
            IClaimRebase(target).claimRebase(reentryTokenId);
        }
        return 0;
    }

    function claimInto(uint256, uint256) external returns (uint256) {
        if (target != address(0)) {
            IClaimRebase(target).claimRebase(reentryTokenId);
        }
        return 0;
    }
}
