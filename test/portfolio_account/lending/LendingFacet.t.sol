// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {Setup} from "../utils/Setup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";

contract LendingFacetTest is Test, Setup {
    LendingFacet public lendingFacet;
    
    uint256 public borrowAmount = 1000e6; // 1000 USDC
    uint256 public payAmount = 500e6; // 500 USDC

    function setUp() public override {
        super.setUp();
        
        // LendingFacet should already be deployed via DeployFacets in Setup
        lendingFacet = LendingFacet(_portfolioAccount);
    }

    function testBorrowIncreasesDebt() public {
        // Add collateral first
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Verify initial debt is zero
        uint256 initialDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(initialDebt, 0, "Initial debt should be zero");
        
        // Borrow amount
        lendingFacet.borrow(borrowAmount);
        
        // Verify debt increased
        uint256 newDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(newDebt, borrowAmount, "Debt should equal borrow amount");
        vm.stopPrank();
    }

    function testBorrowMultipleTimes() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        uint256 firstBorrow = 500e6;
        uint256 secondBorrow = 300e6;
        
        lendingFacet.borrow(firstBorrow);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), firstBorrow, "Debt should equal first borrow");
        
        lendingFacet.borrow(secondBorrow);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), firstBorrow + secondBorrow, "Debt should equal sum of borrows");
        vm.stopPrank();
    }

    function testBorrowFailsWithoutCollateral() public {
        vm.startPrank(_user);
        // Try to borrow without adding collateral
        vm.expectRevert();
        lendingFacet.borrow(borrowAmount);
        vm.stopPrank();
    }

    function testBorrowFailsWhenExceedsMaxLoan() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Get max loan amount
        int128 lockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        uint256 totalLockedCollateral = uint256(uint128(lockedAmount));
        
        // Calculate max loan (this would depend on rewardsRate and multiplier)
        // For now, we'll try to borrow an extremely large amount
        uint256 excessiveAmount = type(uint256).max;
        
        vm.expectRevert();
        lendingFacet.borrow(excessiveAmount);
        vm.stopPrank();
    }

    function testPayDecreasesDebt() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow first
        lendingFacet.borrow(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount, "Debt should equal borrow amount");
        
        // Pay partial amount
        lendingFacet.pay(payAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount - payAmount, "Debt should decrease by pay amount");
        vm.stopPrank();
    }

    function testPayFullAmount() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow
        lendingFacet.borrow(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount, "Debt should equal borrow amount");
        
        // Pay full amount
        lendingFacet.pay(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt should be zero after full payment");
        vm.stopPrank();
    }

    function testPayMultipleTimes() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow
        lendingFacet.borrow(borrowAmount);
        
        // Pay multiple times
        uint256 firstPay = 300e6;
        uint256 secondPay = 200e6;
        
        lendingFacet.pay(firstPay);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount - firstPay, "Debt should decrease after first payment");
        
        lendingFacet.pay(secondPay);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount - firstPay - secondPay, "Debt should decrease after second payment");
        vm.stopPrank();
    }

    function testPayMoreThanDebt() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow
        lendingFacet.borrow(borrowAmount);
        
        // Pay more than debt - this will cause an underflow
        // The implementation doesn't protect against this, so we expect it to revert
        uint256 overpay = borrowAmount + 100e6;
        vm.expectRevert();
        lendingFacet.pay(overpay);
        vm.stopPrank();
    }

    function testBorrowAndPayCycle() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow
        lendingFacet.borrow(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount, "Debt should equal borrow amount");
        
        // Pay partial
        lendingFacet.pay(payAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount - payAmount, "Debt should decrease");
        
        // Borrow again
        uint256 secondBorrow = 200e6;
        lendingFacet.borrow(secondBorrow);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount - payAmount + secondBorrow, "Debt should increase");
        
        // Pay remaining
        lendingFacet.pay(borrowAmount - payAmount + secondBorrow);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt should be zero");
        vm.stopPrank();
    }

    function testBorrowWithZeroAmount() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow zero amount (should not revert, but debt should remain 0)
        lendingFacet.borrow(0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt should remain zero");
        vm.stopPrank();
    }

    function testPayWithZeroAmount() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow first
        lendingFacet.borrow(borrowAmount);
        
        // Pay zero amount (should not revert, but debt should remain same)
        lendingFacet.pay(0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount, "Debt should remain same");
        vm.stopPrank();
    }

    function testBorrowAndRemoveCollateral() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Borrow
        lendingFacet.borrow(borrowAmount);
        
        // Try to remove collateral with debt (should revert)
        vm.expectRevert();
        CollateralFacet(_portfolioAccount).removeCollateral(_tokenId);
        
        // Pay debt
        lendingFacet.pay(borrowAmount);
        
        // Now should be able to remove collateral
        CollateralFacet(_portfolioAccount).removeCollateral(_tokenId);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt should be zero");
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0, "Collateral should be removed");
        vm.stopPrank();
    }

    function testGetTotalDebt() public {
        vm.startPrank(_user);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        
        // Initially zero
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Initial debt should be zero");
        
        // After borrowing
        lendingFacet.borrow(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount, "Debt should match borrow amount");
        
        // After partial payment
        lendingFacet.pay(payAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount - payAmount, "Debt should decrease after payment");
        vm.stopPrank();
    }
}

