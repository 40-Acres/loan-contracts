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

    // Helper function to add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to pay via PortfolioManager multicall
    function payViaMulticall(uint256 tokenId, uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.pay.selector,
            tokenId,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Assert that CollateralManager debt matches LoanV2 balance for a single tokenId
    function _assertDebtSynced(uint256 tokenId) internal view {
        uint256 collateralManagerDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        (uint256 loanBalance,) = ILoan(_portfolioAccountConfig.getLoanContract()).getLoanDetails(tokenId);
        assertEq(collateralManagerDebt, loanBalance, "CollateralManager debt should match LoanV2 balance");
    }

    function testBorrowWithCollateral() public {
        // Add collateral first
        addCollateralViaMulticall(_tokenId);
        
        uint256 borrowAmount = 1e6; // 1 USDC
        
        // Borrow against collateral
        borrowViaMulticall(borrowAmount);
        
        // Check debt is tracked (includes 0.8% origination fee)
        uint256 expectedDebt = _withFee(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedDebt);
        
        // Verify CollateralManager and LoanV2 are in sync
        _assertDebtSynced(_tokenId);
    }

    function testBorrowFailsWithoutCollateral() public {
        // Should revert - no collateral added
        vm.expectRevert();
        borrowViaMulticall(1e6);
    }

    function testBorrowFailsWithoutOwningToken() public {
        // Transfer token out of portfolio first (need to prank as portfolio account)
        vm.startPrank(_portfolioAccount);
        IVotingEscrow(_ve).transferFrom(_portfolioAccount, address(0xdead), _tokenId);
        vm.stopPrank();
        
        // Should revert - portfolio doesn't own token
        vm.expectRevert("Portfolio does not own token");
        borrowViaMulticall(1e6);
    }

    function testPayLoan() public {
        // Setup: add collateral and borrow
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 1e6;
        borrowViaMulticall(borrowAmount);
        
        uint256 expectedDebt = _withFee(borrowAmount);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedDebt);
        _assertDebtSynced(_tokenId);
        
        // Fund portfolio with extra USDC for fee payment (borrow only gives principal)
        // deal() replaces balance, so add to existing balance
        uint256 currentBalance = _asset.balanceOf(_portfolioAccount);
        deal(address(_asset), _portfolioAccount, currentBalance + expectedDebt);
        
        // Pay back the full loan balance (including fee)
        payViaMulticall(_tokenId, expectedDebt);
        
        // Debt should be zero
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        _assertDebtSynced(_tokenId);
    }

    function testPartialPayment() public {
        // Setup: add collateral and borrow
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 2e6; // 2 USDC
        borrowViaMulticall(borrowAmount);
        
        _assertDebtSynced(_tokenId);
        
        // Pay back half of the original amount
        uint256 payAmount = 1e6;
        payViaMulticall(_tokenId, payAmount);
        
        // Debt should be reduced (original debt with fee minus payment)
        uint256 expectedBalance = _withFee(borrowAmount) - payAmount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedBalance);
        _assertDebtSynced(_tokenId);
    }

    function testIncreaseLoan() public {
        // Setup: add collateral and initial borrow
        addCollateralViaMulticall(_tokenId);
        uint256 initialBorrow = 1e6;
        borrowViaMulticall(initialBorrow);
        
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), _withFee(initialBorrow));
        _assertDebtSynced(_tokenId);
        
        // Borrow more (should increase existing loan)
        uint256 additionalBorrow = 1e6;
        borrowViaMulticall(additionalBorrow);
        
        // Total debt should be sum of both borrows (each with fee)
        uint256 expectedDebt = _withFee(initialBorrow) + _withFee(additionalBorrow);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedDebt);
        _assertDebtSynced(_tokenId);
    }

    function testBorrowExceedsCollateral() public {
        // Add collateral
        addCollateralViaMulticall(_tokenId);
        
        // Try to borrow way more than collateral allows
        uint256 excessiveBorrow = 1000000e6; // 1M USDC - should exceed max loan
        
        vm.expectRevert();
        borrowViaMulticall(excessiveBorrow);
    }

    function testDebtTrackedAcrossMultipleTokens() public {
        uint256 tokenId2 = 84298;
        
        // Transfer second token to portfolio
        vm.startPrank(IVotingEscrow(_ve).ownerOf(tokenId2));
        IVotingEscrow(_ve).transferFrom(IVotingEscrow(_ve).ownerOf(tokenId2), _portfolioAccount, tokenId2);
        vm.stopPrank();
        
        // Add both as collateral
        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(tokenId2);
        
        // Borrow against first token
        uint256 borrow1 = 1e6;
        borrowViaMulticall(borrow1);
        
        // Borrow against second token
        uint256 borrow2 = 2e6;
        borrowViaMulticall(borrow2);
        
        // Total debt should be sum of both (with fees)
        uint256 expectedTotalDebt = _withFee(borrow1) + _withFee(borrow2);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedTotalDebt);
        
        // Verify individual loan balances match
        (uint256 loan1Balance,) = ILoan(_portfolioAccountConfig.getLoanContract()).getLoanDetails(_tokenId);
        (uint256 loan2Balance,) = ILoan(_portfolioAccountConfig.getLoanContract()).getLoanDetails(tokenId2);
        assertEq(loan1Balance + loan2Balance, expectedTotalDebt, "Sum of loan balances should match total debt");
    }
}
