// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Errors} from "./Errors.sol";

interface ILoanMinimalBalance {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
}

interface IVotingEscrowMinimalOwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

library TransferGuardsLib {
    function enforceNoDebtBeforeTransfer(address loan, uint256 tokenId) internal view {
        (uint256 balance,) = ILoanMinimalBalance(loan).getLoanDetails(tokenId);
        if (balance != 0) revert Errors.DebtNotCleared();
    }

    function requireCustody(address votingEscrow, uint256 tokenId, address expectedOwner) internal view {
        if (IVotingEscrowMinimalOwnerOf(votingEscrow).ownerOf(tokenId) != expectedOwner) revert Errors.BadCustody();
    }
}


