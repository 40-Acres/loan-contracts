// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { PharaohLoanV2 } from "./PharaohLoanV2.sol";
import { LoanUtils } from "../LoanUtils.sol";

contract PharaohLoanV2Native is PharaohLoanV2 {

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
            _getLockedAmount(tokenId),
            getRewardsRate(),
            _asset.balanceOf(_vault),
            _outstandingCapital,
            _loanDetails[tokenId].balance
        );
    }

    function _entryPoint() internal view override returns (address) {
        return 0x98259FB9882f0a873B9eB3F547529d24412bdC2f;
    }
}