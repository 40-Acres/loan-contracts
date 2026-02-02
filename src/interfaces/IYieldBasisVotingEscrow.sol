// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IYieldBasisVotingEscrow
 * @dev Interface for YieldBasis veYB (vote-escrowed YB) contract on Ethereum
 * Contract: 0x8235c179E9e84688FBd8B12295EfC26834dAC211
 *
 * veYB uses address-based accounting (not NFT-based like Aerodrome).
 * Users lock YB tokens for up to 4 years to receive veYB voting power.
 * Voting power decays linearly until lock expiry.
 * Max-lock (permalock) maintains full voting power indefinitely.
 */
interface IYieldBasisVotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    /// @notice Get the current voting power (veYB balance) for an address
    /// @param addr Address to query
    /// @return Current veYB balance (voting power)
    function balanceOf(address addr) external view returns (uint256);

    /// @notice Get the voting power at a specific timestamp
    /// @param addr Address to query
    /// @param t Timestamp to query
    /// @return veYB balance at the given timestamp
    function balanceOfAt(address addr, uint256 t) external view returns (uint256);

    /// @notice Get the total veYB supply
    /// @return Total veYB supply
    function totalSupply() external view returns (uint256);

    /// @notice Get the total supply at a specific timestamp
    /// @param t Timestamp to query
    /// @return Total veYB supply at the given timestamp
    function totalSupplyAt(uint256 t) external view returns (uint256);

    /// @notice Get locked balance for an address
    /// @param addr Address to query
    /// @return Locked balance struct (amount, end)
    function locked(address addr) external view returns (LockedBalance memory);

    /// @notice Create a new lock
    /// @param value Amount of YB to lock
    /// @param unlock_time Lock end timestamp (must be in future, max 4 years)
    function create_lock(uint256 value, uint256 unlock_time) external;

    /// @notice Increase the locked amount (extends existing lock)
    /// @param value Additional YB to lock
    function increase_amount(uint256 value) external;

    /// @notice Extend the lock duration
    /// @param unlock_time New lock end timestamp (must be greater than current)
    function increase_unlock_time(uint256 unlock_time) external;

    /// @notice Withdraw unlocked tokens after lock expires
    function withdraw() external;

    /// @notice Get the YB token address (Vyper uses uppercase TOKEN)
    /// @return Address of the YB token
    function TOKEN() external view returns (address);

    /// @notice Deposit for another address (if permitted)
    /// @param addr Address to deposit for
    /// @param value Amount to deposit
    function deposit_for(address addr, uint256 value) external;

    /// @notice Checkpoint the veYB state
    function checkpoint() external;

    /// @notice Get user's point history length
    /// @param addr User address
    /// @return Number of history points
    function user_point_epoch(address addr) external view returns (uint256);

    /// @notice Maximum lock time (4 years in seconds)
    function MAXTIME() external view returns (uint256);

    /// @notice Toggle infinite lock for the caller's position
    /// @dev When enabled, lock never expires and maintains full voting power.
    ///      Infinite lock is indicated by lock.end == type(uint256).max
    function infinite_lock_toggle() external;

    // ============ NFT Functions (veYB is transferable) ============

    /// @notice Transfer veYB position to another address
    /// @dev Receiver must have a max-locked position or this will fail
    /// @param from Current owner
    /// @param to New owner
    /// @param tokenId The veYB token ID
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Safe transfer with data
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Get the owner of a veYB token
    /// @param tokenId Token ID
    /// @return Owner address
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Get token ID for an address (if using tokenOfOwnerByIndex)
    /// @param owner Owner address
    /// @param index Index (usually 0)
    /// @return Token ID
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);

    /// @notice Get number of veYB tokens owned by address
    /// @param owner Owner address
    /// @return Balance
    function balanceOfNFT(address owner) external view returns (uint256);
}
