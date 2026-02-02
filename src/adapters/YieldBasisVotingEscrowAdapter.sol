// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IYieldBasisVotingEscrow} from "../interfaces/IYieldBasisVotingEscrow.sol";

/**
 * @title YieldBasisVotingEscrowAdapter
 * @dev Adapts YieldBasis's address-based veYB to match Aerodrome's tokenId-based IVotingEscrow interface.
 *      This allows CollateralManager to work with YieldBasis without code duplication.
 *
 * Key differences handled:
 * - YieldBasis: locked(address) vs Aerodrome: locked(uint256 tokenId)
 * - YieldBasis: no isPermanent, uses max lock time instead
 * - YieldBasis: no lockPermanent(), uses increase_unlock_time() to extend to max
 */
contract YieldBasisVotingEscrowAdapter {
    IYieldBasisVotingEscrow public immutable veYB;

    uint256 public constant MAX_LOCK_TIME = 4 * 365 days;
    uint256 public constant WEEK = 7 days;

    error NotSupported();

    constructor(address _veYB) {
        require(_veYB != address(0), "Invalid veYB address");
        veYB = IYieldBasisVotingEscrow(_veYB);
    }

    /**
     * @notice Get locked balance for a token ID, adapted from address-based lookup
     * @param tokenId The veYB token ID
     * @return LockedBalance struct matching Aerodrome's format
     */
    function locked(uint256 tokenId) external view returns (IVotingEscrow.LockedBalance memory) {
        address owner = veYB.ownerOf(tokenId);
        IYieldBasisVotingEscrow.LockedBalance memory yieldBasisLock = veYB.locked(owner);

        // Infinite lock is indicated by lock.end == type(uint256).max
        // When infinite_lock_toggle() is called, the end time is set to max uint256
        bool isPermanent = yieldBasisLock.end == type(uint256).max;

        return IVotingEscrow.LockedBalance({
            amount: yieldBasisLock.amount,
            end: yieldBasisLock.end,
            isPermanent: isPermanent
        });
    }

    /**
     * @notice No-op - infinite lock must be enabled by the portfolio account directly
     * @dev The adapter cannot call infinite_lock_toggle() because it would affect
     *      the adapter's address, not the portfolio's. YieldBasisFacet handles this
     *      by calling veYB.infinite_lock_toggle() directly when creating/depositing locks.
     * @param tokenId The veYB token ID (unused)
     */
    function lockPermanent(uint256 tokenId) external {
        // No-op: infinite_lock_toggle() must be called by the portfolio account directly
        // YieldBasisFacet.createLock() and depositLock() handle enabling infinite lock
    }

    /**
     * @notice Get the owner of a veYB token
     * @param tokenId The veYB token ID
     * @return Owner address
     */
    function ownerOf(uint256 tokenId) external view returns (address) {
        return veYB.ownerOf(tokenId);
    }

    /**
     * @notice Get the underlying token address
     * @return YB token address
     */
    function token() external view returns (address) {
        return veYB.TOKEN();
    }

    /**
     * @notice Get the veYB balance (voting power) for a token
     * @param tokenId The veYB token ID
     * @return Voting power
     */
    function balanceOfNFT(uint256 tokenId) external view returns (uint256) {
        address owner = veYB.ownerOf(tokenId);
        return veYB.balanceOf(owner);
    }

    /**
     * @notice Calculate the max unlock time rounded to week
     * @return Max unlock timestamp
     */
    function _getMaxUnlockTime() internal view returns (uint256) {
        return ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;
    }
}
