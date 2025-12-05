// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {Setup} from "../utils/Setup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

contract LendingFacetTest is Test, Setup {

    // Origination fee is 0.8% (80/10000)
    function _withFee(uint256 amount) internal pure returns (uint256) {
        return amount + (amount * 80) / 10000;
    }

    // Assert that CollateralManager debt matches LoanV2 balance for a single tokenId
    function _assertDebtSynced(uint256 tokenId) internal view {
        uint256 collateralManagerDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        (uint256 loanBalance,) = ILoan(_portfolioAccountConfig.getLoanContract()).getLoanDetails(tokenId);
        assertEq(collateralManagerDebt, loanBalance, "CollateralManager debt should match LoanV2 balance");
    }

    function testBorrowWithCollateral() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Add collateral first
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        uint256 borrowAmount = 1e6; // 1 USDC
        
        // Borrow against collateral
        LendingFacet(_portfolioAccount).borrow(borrowAmount);
        
        // Check debt is tracked (includes 0.8% origination fee)
        uint256 expectedDebt = _withFee(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedDebt);
        
        // Verify CollateralManager and LoanV2 are in sync
        _assertDebtSynced(_tokenId);
        
        vm.stopPrank();
    }

    function testBorrowFailsWithoutCollateral() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Should revert - no collateral added
        vm.expectRevert();
        LendingFacet(_portfolioAccount).borrow(1e6);
        
        vm.stopPrank();
    }

    function testBorrowFailsWithoutOwningToken() public {
        // Transfer token out of portfolio first (need to prank as portfolio account)
        vm.startPrank(_portfolioAccount);
        IVotingEscrow(_ve).transferFrom(_portfolioAccount, address(0xdead), _tokenId);
        vm.stopPrank();
        
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Should revert - portfolio doesn't own token
        vm.expectRevert("Portfolio does not own token");
        LendingFacet(_portfolioAccount).borrow(1e6);
        
        vm.stopPrank();
    }

    function testPayLoan() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Setup: add collateral and borrow
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        uint256 borrowAmount = 1e6;
        LendingFacet(_portfolioAccount).borrow(borrowAmount);
        
        uint256 expectedDebt = _withFee(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedDebt);
        _assertDebtSynced(_tokenId);
        
        vm.stopPrank();
        
        // Fund portfolio with extra USDC for fee payment (borrow only gives principal)
        // deal() replaces balance, so add to existing balance
        uint256 currentBalance = _asset.balanceOf(_portfolioAccount);
        deal(address(_asset), _portfolioAccount, currentBalance + expectedDebt);
        
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Pay back the full loan balance (including fee)
        LendingFacet(_portfolioAccount).pay(_tokenId, expectedDebt);
        
        // Debt should be zero
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        _assertDebtSynced(_tokenId);
        
        vm.stopPrank();
    }

    function testPartialPayment() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Setup: add collateral and borrow
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        uint256 borrowAmount = 2e6; // 2 USDC
        LendingFacet(_portfolioAccount).borrow(borrowAmount);
        
        _assertDebtSynced(_tokenId);
        
        // Pay back half of the original amount
        uint256 payAmount = 1e6;
        LendingFacet(_portfolioAccount).pay(_tokenId, payAmount);
        
        // Debt should be reduced (original debt with fee minus payment)
        uint256 expectedBalance = _withFee(borrowAmount) - payAmount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedBalance);
        _assertDebtSynced(_tokenId);
        
        vm.stopPrank();
    }

    function testIncreaseLoan() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Setup: add collateral and initial borrow
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        uint256 initialBorrow = 1e6;
        LendingFacet(_portfolioAccount).borrow(initialBorrow);
        
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), _withFee(initialBorrow));
        _assertDebtSynced(_tokenId);
        
        // Borrow more (should increase existing loan)
        uint256 additionalBorrow = 1e6;
        LendingFacet(_portfolioAccount).borrow(additionalBorrow);
        
        // Total debt should be sum of both borrows (each with fee)
        uint256 expectedDebt = _withFee(initialBorrow) + _withFee(additionalBorrow);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedDebt);
        _assertDebtSynced(_tokenId);
        
        vm.stopPrank();
    }

    function testBorrowExceedsCollateral() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Add collateral
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Try to borrow way more than collateral allows
        uint256 excessiveBorrow = 1000000e6; // 1M USDC - should exceed max loan
        
        vm.expectRevert();
        LendingFacet(_portfolioAccount).borrow(excessiveBorrow);
        
        vm.stopPrank();
    }

    function testDebtTrackedAcrossMultipleTokens() public {
        uint256 tokenId2 = 84298;
        
        // Transfer second token to portfolio
        vm.startPrank(IVotingEscrow(_ve).ownerOf(tokenId2));
        IVotingEscrow(_ve).transferFrom(IVotingEscrow(_ve).ownerOf(tokenId2), _portfolioAccount, tokenId2);
        vm.stopPrank();
        
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        
        // Add both as collateral
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        CollateralFacet(_portfolioAccount).addCollateral(tokenId2);
        
        // Borrow against first token
        uint256 borrow1 = 1e6;
        LendingFacet(_portfolioAccount).borrow(borrow1);
        
        // Borrow against second token
        uint256 borrow2 = 2e6;
        LendingFacet(_portfolioAccount).borrow(borrow2);
        
        // Total debt should be sum of both (with fees)
        uint256 expectedTotalDebt = _withFee(borrow1) + _withFee(borrow2);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedTotalDebt);
        
        // Verify individual loan balances match
        (uint256 loan1Balance,) = ILoan(_portfolioAccountConfig.getLoanContract()).getLoanDetails(_tokenId);
        (uint256 loan2Balance,) = ILoan(_portfolioAccountConfig.getLoanContract()).getLoanDetails(tokenId2);
        assertEq(loan1Balance + loan2Balance, expectedTotalDebt, "Sum of loan balances should match total debt");
        
        vm.stopPrank();
    }
}
