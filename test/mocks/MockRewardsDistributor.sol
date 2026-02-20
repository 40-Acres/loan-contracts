// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title MockRewardsDistributor
 * @dev Minimal RewardsDistributor mock for local testing.
 *      Returns 0 for claimable/claim by default; configurable per tokenId.
 */
contract MockRewardsDistributor {
    mapping(uint256 => uint256) private _claimable;

    function claimable(uint256 tokenId) external view returns (uint256) {
        return _claimable[tokenId];
    }

    function claim(uint256) external pure returns (uint256) {
        return 0;
    }

    function claimMany(uint256[] calldata) external pure returns (bool) {
        return true;
    }

    // ── Test helpers ───────────────────────────────────────────────────

    function setClaimable(uint256 tokenId, uint256 amount) external {
        _claimable[tokenId] = amount;
    }
}
