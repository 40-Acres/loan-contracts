// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IHydrexVotingEscrow} from "../../../../src/interfaces/IHydrexVotingEscrow.sol";
import {MockHydrexVotingEscrow} from "./MockHydrexVotingEscrow.sol";

/// @notice Minimal mock of the oHYDX option token. The facet (VeHydrexClaimingFacet)
///         reads `balanceOf(account)` and calls `exerciseVe(amount, recipient)` on a
///         hardcoded constant address, so this mock's runtime code is etched onto
///         that constant address in the test. exerciseVe mints a fresh veNFT on the
///         MockHydrexVotingEscrow (via mintTo, the unsafe _mint analogue -- no
///         receiver hook) and returns its id.
contract MockOptionToken {
    MockHydrexVotingEscrow public ve;

    mapping(address => uint256) internal _balances;

    // Records the most recent exerciseVe call for assertions.
    uint256 public lastExercisedAmount;
    address public lastRecipient;
    uint256 public exerciseCalls;

    function setVe(address ve_) external {
        ve = MockHydrexVotingEscrow(ve_);
    }

    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Redeem `amount` of option tokens into a fresh veNFT held by `recipient`.
    ///         Mints a PERMANENT lock of `amount` on the mock VE (no receiver hook,
    ///         matching the unsafe _mint path) and returns the new token id.
    function exerciseVe(uint256 amount, address recipient) external returns (uint256 newTokenId) {
        exerciseCalls++;
        lastExercisedAmount = amount;
        lastRecipient = recipient;
        // Burn the redeemed balance so a repeated claim does not re-exercise.
        _balances[recipient] = 0;
        newTokenId = ve.mintTo(recipient, amount, IHydrexVotingEscrow.LockType.PERMANENT);
    }
}
