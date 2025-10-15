// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../interfaces/ILoan.sol";

interface IXPharaohLoan {
    
    enum ZeroBalanceOption {
        DoNothing,
        InvestToVault,
        PayToOwner
    }

    struct LoanInfo {
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
        ZeroBalanceOption zeroBalanceOption;
        uint256 voteTimestamp;
        uint256 unpaidFees;
        address preferredToken;
        uint256 increasePercentage;
        bool topUp;
    }
    function migrateNft(address user, uint256 tokenId, uint256 balance, uint256 outstandingCapital, address preferredToken, uint256 increasePercentage, bool topUp, uint8 zeroBalanceOption, uint256 unpaidFees) external;
    function getLoanDetails(address user) external view returns (uint256 balance, address borrower);
}