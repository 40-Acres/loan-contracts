// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../../interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LendingFacet
 * @dev Facet for borrowing against collateral in portfolio accounts.
 *      Global debt tracked via CollateralManager, per-loan details from loan contract.
 */
contract LendingFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;

    error NotOwnerOfToken();
    error NotPortfolioOwner();

    constructor(address portfolioFactory, address portfolioAccountConfig) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
    }

    function borrow(uint256 tokenId, uint256 amount) public {
        ILoan loanContract = ILoan(_portfolioAccountConfig.getLoanContract());
        address loanAddr = address(loanContract);

        // Get the voting escrow from the loan contract
        IVotingEscrow ve = IVotingEscrow(loanContract._ve());

        // Ensure the portfolio account owns the token
        require(ve.ownerOf(tokenId) == address(this), "Portfolio does not own token");

        // Check if there's already a loan for this tokenId
        (uint256 balanceBefore, address borrower) = loanContract.getLoanDetails(tokenId);

        if (balanceBefore == 0) {
            // Approve loan contract to manage the token (needed for lockPermanent)
            ve.approve(loanAddr, tokenId);

            // No existing loan - request a new loan
            loanContract.requestLoan(
                tokenId,
                amount,
                ILoan.ZeroBalanceOption.DoNothing,
                0, // increasePercentage
                address(0), // preferredToken
                false, // topUp
                false // optInCommunityRewards
            );
        } else {
            // Existing loan - increase it
            require(borrower == address(this), "Loan not owned by portfolio");
            loanContract.increaseLoan(tokenId, amount);
        }

        // Track actual debt increase (includes origination fee)
        (uint256 balanceAfter,) = loanContract.getLoanDetails(tokenId);
        uint256 debtIncrease = balanceAfter - balanceBefore;
        CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), debtIncrease);
    }

    function pay(uint256 tokenId, uint256 amount) public {
        ILoan loanContract = ILoan(_portfolioAccountConfig.getLoanContract());
        address loanAddr = address(loanContract);

        // Get balance before payment
        (uint256 balanceBefore,) = loanContract.getLoanDetails(tokenId);

        // Approve loan contract to transfer USDC for payment
        IERC20 asset = IERC20(loanContract._asset());
        asset.approve(loanAddr, amount);

        // Pay down the loan
        loanContract.pay(tokenId, amount);

        // Track actual debt decrease
        (uint256 balanceAfter,) = loanContract.getLoanDetails(tokenId);
        uint256 debtDecrease = balanceBefore - balanceAfter;
        CollateralManager.decreaseTotalDebt(debtDecrease);
    }
}