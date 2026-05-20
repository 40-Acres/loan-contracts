// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHydrexVotingEscrow {
    enum LockType {
        NON_PERMANENT,
        ROLLING,
        PERMANENT
    }

    struct LockDetails {
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        LockType lockType;
    }

    error LockDurationNotInFuture();
    error LockDurationTooLong();
    error LockExpired();
    error LockHoldsValue();
    error NotPermanentLock();
    error PermanentLock();
    error PermanentLockMismatch();
    error RollingLockMismatch();
    error SameNFT();
    error ZeroAmount();

    function token() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;

    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function balanceOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256);
    function lockDetails(uint256 tokenId) external view returns (LockDetails memory);
    function totalNftsMinted() external view returns (uint256);

    function createLock(uint256 value, uint256 duration, LockType lockType) external returns (uint256 tokenId);
    function increaseAmount(uint256 tokenId, uint256 value) external;
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration, bool permanent) external;
    function unlockRolling(uint256 tokenId) external;

    function merge(uint256 from, uint256 to) external;
    function split(uint256[] memory weights, uint256 tokenId) external;
}
