// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IXLoan} from "./IXLoan.sol";

/**
 * @title IXRexFacet
 * @dev Interface for XRexFacet contract
 */
interface IXRexFacet {
    /**
     * @dev Claim collateral from xREX position
     * @param loanContract The loan contract address
     * @param amount The amount to claim
     */
    function xRexClaimCollateral(address loanContract, uint256 amount) external;

    /**
     * @dev Increase loan amount using xREX collateral
     * @param loanContract The loan contract address
     * @param amount The amount to increase loan by
     */
    function xRexIncreaseLoan(address loanContract, uint256 amount) external;

    /**
     * @dev Request a loan using xREX as collateral
     * @param loanContract The loan contract address
     * @param loanAmount The amount to borrow
     * @param zeroBalanceOption Option for handling zero balance
     * @param increasePercentage Percentage increase for loan
     * @param preferredToken Preferred token for the loan
     * @param topUp Whether to top up the position
     */
    function xRexRequestLoan(
        address loanContract,
        uint256 loanAmount,
        IXLoan.ZeroBalanceOption zeroBalanceOption,
        uint256 increasePercentage,
        address preferredToken,
        bool topUp
    ) external;

    /**
     * @dev Vote on behalf of user using xREX voting power
     * @param loanContract The loan contract address
     * @param pools Array of pool addresses to vote for
     * @param weights Array of voting weights for each pool
     */
    function xRexUserVote(
        address loanContract,
        address[] calldata pools,
        uint256[] calldata weights
    ) external;

    /**
     * @dev Claim rewards and handle allocations
     * @param loanContract The loan contract address
     * @param fees Array of fee addresses
     * @param tokens Array of token arrays for trading
     * @param tradeData Encoded trade data
     * @param allocations Array of allocation amounts
     * @return The result of the claim operation
     */
    function xRexClaim(
        address loanContract,
        address[] calldata fees,
        address[][] calldata tokens,
        bytes calldata tradeData,
        uint256[2] calldata allocations
    ) external returns (uint256);

    /**
     * @dev Vote using xREX voting power
     * @param loanContract The loan contract address
     * @return Whether the vote was successful
     */
    function xRexVote(address loanContract) external returns (bool);
}


