// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Loan } from "./LoanV2.sol";
import { LoanUtils } from "./LoanUtils.sol";

contract LoanV2Native is Loan {

        /* ORACLE */
    function confirmUsdcPrice() internal view override returns (bool) {
        return true;
    }


    /**
     * @notice Calculates the maximum loan amount that can be borrowed for a given token ID.
     * @dev This function forwards the call to the LoanCalculator contract.
     * @param tokenId The ID of the loan (NFT).
     * @return maxLoan The maximum loan amount that can be borrowed.
     * @return maxLoanIgnoreSupply The maximum loan amount ignoring vault supply constraints.
     */
    function getMaxLoan(
        uint256 tokenId
    ) public override view returns (uint256, uint256) {
        return LoanUtils.getMaxLoanByLtv(
            tokenId,
            address(_ve),
            getRewardsRate(),
            _asset.balanceOf(_vault),
            _outstandingCapital,
            _loanDetails[tokenId].balance
        );
    }
}