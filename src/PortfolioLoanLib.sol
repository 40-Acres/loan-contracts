// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IPortfolioFactory} from "./accounts/IPortfolioFactory.sol";
import {IMigrationFacet} from "./facets/account/migration/IMigrationFacet.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";

/**
 * @title PortfolioLoanLib
 * @dev Library for portfolio account loan operations.
 *      Extracted from Loan contract to reduce contract size.
 *      External functions are deployed separately and called via DELEGATECALL.
 */
library PortfolioLoanLib {
    event LoanPaid(uint256 tokenId, address borrower, uint256 amount, uint256 epoch, bool isManual);
    event ProtocolFeePaid(uint256 epoch, uint256 amount, address borrower, uint256 tokenId, address token);
    event FundsBorrowed(uint256 tokenId, address owner, uint256 amount);

    /**
     * @notice Migrates a loan to be controlled by the user's portfolio account.
     * @param tokenId The ID of the loan to migrate.
     * @param borrower The borrower address (must equal msg.sender).
     * @param unpaidFees The unpaid fees on the loan.
     * @param factory The portfolio factory address.
     * @param ve The voting escrow contract.
     */
    function migrateToPortfolio(
        uint256 tokenId,
        address borrower,
        uint256 unpaidFees,
        address factory,
        IVotingEscrow ve
    ) external {
        require(borrower == msg.sender);
        require(factory != address(0));

        address portfolio = IPortfolioFactory(factory).portfolioOf(msg.sender);
        if (portfolio == address(0)) {
            portfolio = IPortfolioFactory(factory).createAccount(msg.sender);
        }

        ve.approve(portfolio, tokenId);
        IMigrationFacet(portfolio).migrate(tokenId, unpaidFees);
    }

    /**
     * @notice Processes a payment from a portfolio account.
     * @param totalPayment The total payment amount.
     * @param feesToPay The portion of payment that is fees.
     * @param factory The portfolio factory address.
     * @param asset The lending asset (USDC).
     * @param vault The vault address.
     * @param contractOwner The protocol owner address (receives fees).
     * @return capitalReduction The amount to subtract from _outstandingCapital.
     */
    function payFromPortfolio(
        uint256 totalPayment,
        uint256 feesToPay,
        address factory,
        IERC20 asset,
        address vault,
        address contractOwner
    ) external returns (uint256 capitalReduction) {
        require(factory != address(0));

        address portfolioOwner = IPortfolioFactory(factory).ownerOf(msg.sender);
        require(portfolioOwner != address(0));

        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        // Handle unpaid fees first - transfer to protocol owner
        if (feesToPay > 0) {
            asset.transferFrom(msg.sender, contractOwner, feesToPay);
            emit LoanPaid(0, portfolioOwner, feesToPay, epochStart, true);
            emit ProtocolFeePaid(epochStart, feesToPay, portfolioOwner, 0, address(asset));
        }

        // Transfer remaining amount to vault
        capitalReduction = totalPayment - feesToPay;
        if (capitalReduction > 0) {
            asset.transferFrom(msg.sender, vault, capitalReduction);
            emit LoanPaid(0, portfolioOwner, capitalReduction, epochStart, false);
        }
    }

    /**
     * @notice Processes a borrow from a portfolio account.
     * @param amount The amount to borrow.
     * @param factory The portfolio factory address.
     * @param asset The lending asset (USDC).
     * @param vault The vault address.
     * @param contractOwner The protocol owner address (receives origination fee).
     * @return originationFee The origination fee charged.
     */
    function borrowFromPortfolio(
        uint256 amount,
        address factory,
        IERC20 asset,
        address vault,
        address contractOwner
    ) external returns (uint256 originationFee) {
        require(factory != address(0));

        address portfolioOwner = IPortfolioFactory(factory).ownerOf(msg.sender);
        require(portfolioOwner != address(0));

        originationFee = (amount * 80) / 10000; // 0.8%

        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        // Transfer origination fee to owner upfront
        asset.transferFrom(vault, contractOwner, originationFee);
        emit ProtocolFeePaid(epochStart, originationFee, portfolioOwner, 0, address(asset));

        // Transfer remaining amount to portfolio account
        asset.transferFrom(vault, msg.sender, amount - originationFee);
        emit FundsBorrowed(0, portfolioOwner, amount);
    }
}
