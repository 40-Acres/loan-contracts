pragma solidity ^0.8.28;

import { IVoter } from "../../interfaces/IVoter.sol";
import "../../libraries/LoanLibrary.sol";

// 0x16613524e02ad97edfef371bc883f2f5d6c480a5
contract VelodromeVenft {
    using LoanLibrary for LoanLibrary.LoanInfo;
    
    IVoter public voter = IVoter(0x16613524e02ad97edfef371bc883f2f5d6c480a5);
    address private _pool;
    mapping(uint256 => LoanLibrary.LoanInfo) private _loans;

    function createLoan(address token, uint256 tokenId, address borrower, uint256 expiration) public returns (LoanLibrary.LoanInfo memory) {
        // create a loan
        LoanLibrary.LoanInfo memory loan = LoanLibrary.LoanInfo({
            tokenAddress: token,
            tokenId: tokenId,
            initialLoanAmount: 0,
            amountPaid: 0,
            startTime: block.timestamp,
            endTime: expiration,
            borrower: borrower,
            active: true
        });

        _loans[tokenId] = loan;
        return loan;
    }

    function paybackLoan() public {
        voter.claimFees(_fees, _tokens, _tokenId);

    }

    function getLoan() public {

    }
}