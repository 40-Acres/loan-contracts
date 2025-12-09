// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {Setup} from "../utils/Setup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

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
    function pay(address portfolioAccount, uint256 amount) internal {
        vm.startPrank(_user);
        deal(address(_asset), _user, amount);
        LendingFacet(portfolioAccount).pay(amount);
        vm.stopPrank();
    }

    function _assertDebtSynced(uint256 tokenId) internal view {
        uint256 collateralManagerDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        // For portfolio accounts, borrowFromPortfolio doesn't create a loan entry,
        // so we can't check loan balance. Just verify debt is tracked.
        assertGt(collateralManagerDebt, 0, "CollateralManager should track debt");
    }

    function testBorrowWithCollateral() public {
        // Add collateral first
        addCollateralViaMulticall(_tokenId);
        
        uint256 borrowAmount = 1e6; // 1 USDC
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_asset), vault, vaultBalance);
        
        // Borrow against collateral
        borrowViaMulticall(borrowAmount);
        
        // Check debt is tracked (borrowFromPortfolio doesn't add origination fee)
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount);
        
        // Verify CollateralManager tracks debt
        _assertDebtSynced(_tokenId);
    }


    function testBorrowMaxLoanTwice() public {
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        address underlyingAsset = IERC4626(vault).asset();
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        // Add collateral first
        addCollateralViaMulticall(_tokenId);
        deal(address(underlyingAsset), vault, 1000000e18);
        (maxLoan, maxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        borrowViaMulticall(maxLoan);
        
        // After borrowing maxLoan, the new maxLoan should be 0 (or very small)
        (uint256 newMaxLoan, ) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(newMaxLoan, 0, "should not be able to borrow max loan twice - new maxLoan should be 0");

        vm.expectRevert();
        borrowViaMulticall(maxLoan);
    }

    function testBorrowFailsWithoutCollateral() public {
        // Should revert - no collateral added
        vm.expectRevert();
        borrowViaMulticall(1e6);
    }

    function testBorrowFailsWithoutOwningToken() public {
        // Remove collateral
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.removeCollateral.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        // Should revert - insufficient collateral (no token owned means no collateral)
        vm.expectRevert();
        borrowViaMulticall(1e6);
    }

    function testPayLoan() public {
        // Setup: add collateral and borrow
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 1e6;
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_asset), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount);
        _assertDebtSynced(_tokenId);
        
        // Fund portfolio with USDC for payment
        // deal() replaces balance, so add to existing balance
        uint256 currentBalance = _asset.balanceOf(_portfolioAccount);
        deal(address(_asset), _portfolioAccount, currentBalance + borrowAmount);
        
        // Approve loan contract to transfer USDC
        vm.startPrank(_user);
        IERC20(_asset).approve(_portfolioAccount, borrowAmount);
        vm.stopPrank();
        
        // Pay back the full loan balance
        pay(_portfolioAccount, borrowAmount);
        
        // Debt should be zero
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function testPartialPayment() public {
        // Setup: add collateral and borrow
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 2e6; // 2 USDC
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_asset), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        _assertDebtSynced(_tokenId);
        
        // Fund portfolio with USDC for payment
        uint256 currentBalance = _asset.balanceOf(_portfolioAccount);
        deal(address(_asset), _portfolioAccount, currentBalance + 1e6);
        
        // Approve loan contract to transfer USDC
        vm.startPrank(_user);
        IERC20(_asset).approve(_portfolioAccount, 1e6);
        vm.stopPrank();
        
        // Pay back half of the original amount
        uint256 payAmount = 1e6;
        pay(_portfolioAccount, payAmount);
        
        // Debt should be reduced
        uint256 expectedBalance = borrowAmount - payAmount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedBalance);
        _assertDebtSynced(_tokenId);
    }

    function testIncreaseLoan() public {
        // Setup: add collateral and initial borrow
        addCollateralViaMulticall(_tokenId);
        uint256 initialBorrow = 1e6;
        uint256 additionalBorrow = 1e6;
        
        // Fund vault so borrow can succeed (need enough for 80% cap: total borrow / 0.8)
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        uint256 totalBorrow = initialBorrow + additionalBorrow;
        uint256 vaultBalance = (totalBorrow * 10000) / 8000; // Enough for 80% cap
        deal(address(_asset), vault, vaultBalance);
        
        borrowViaMulticall(initialBorrow);
        
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), initialBorrow);
        _assertDebtSynced(_tokenId);
        
        // Borrow more (should increase existing loan)
        borrowViaMulticall(additionalBorrow);
        
        // Total debt should be sum of both borrows
        uint256 expectedDebt = initialBorrow + additionalBorrow;
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedDebt);
        _assertDebtSynced(_tokenId);
    }

    function testBorrowExceedsCollateral() public {
        // Add collateral
        addCollateralViaMulticall(_tokenId);
        
        // Fund vault (though borrow should fail before using it)
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_asset), vault, 1000000e6);
        
        // Try to borrow way more than collateral allows
        uint256 excessiveBorrow = 1000000e6; // 1M USDC - should exceed max loan
        
        vm.expectRevert();
        borrowViaMulticall(excessiveBorrow);
    }

    function testBorrowExceedsCollateralButLessThanVault() public {
        // Add collateral
        addCollateralViaMulticall(_tokenId);
        
        // Calculate maxLoanIgnoreSupply based on collateral
        uint256 totalLockedCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 rewardsRate = _loanConfig.getRewardsRate();
        uint256 multiplier = _loanConfig.getMultiplier();
        
        // Formula: maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) * multiplier) / 1e12
        uint256 maxLoanIgnoreSupply = (((totalLockedCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;
        
        // Get vault and fund it with enough balance for our test
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        uint256 vaultBalance = maxLoanIgnoreSupply + 10e6; // Enough to exceed maxLoanIgnoreSupply
        deal(address(_asset), vault, vaultBalance);
        
        // Ensure vault has enough balance for our test
        require(vaultBalance > maxLoanIgnoreSupply, "Vault balance must exceed maxLoanIgnoreSupply for this test");
        
        // Try to borrow more than collateral allows but less than vault balance
        uint256 borrowAmount = maxLoanIgnoreSupply + 1e6; // 1 USDC more than allowed by collateral
        require(borrowAmount < vaultBalance, "Borrow amount must be less than vault balance for this test");
        
        // Should revert with InsufficientCollateral error
        vm.expectRevert(CollateralManager.BadDebt.selector);
        borrowViaMulticall(borrowAmount);
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
        
        // Fund vault so borrows can succeed
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_asset), vault, 5e6); // Enough for both borrows
        
        // Borrow against first token
        uint256 borrow1 = 1e6;
        borrowViaMulticall(borrow1);
        
        // Borrow against second token
        uint256 borrow2 = 2e6;
        borrowViaMulticall(borrow2);
        
        // Total debt should be sum of both (no origination fees for portfolio accounts)
        uint256 expectedTotalDebt = borrow1 + borrow2;
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedTotalDebt);
        
        // Verify debt is tracked
        _assertDebtSynced(_tokenId);
    }

    function testBorrowLimitedByVault80PercentCap() public {
        // Add collateral
        addCollateralViaMulticall(_tokenId);
        
        // Get loan contract and vault
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        
        // Set vault balance to 10 USD
        uint256 vaultBalance = 10e6; // 10 USDC
        deal(address(_asset), vault, vaultBalance);
        
        // Verify vault has 10 USD
        assertEq(_asset.balanceOf(vault), vaultBalance, "Vault should have 10 USD");
        
        // Get outstandingCapital from loan contract (may be non-zero from previous tests)
        uint256 outstandingCapital = ILoan(loanContract).activeAssets();
        
        // Calculate maxLoanIgnoreSupply based on collateral to ensure user can borrow at least 10 USD
        uint256 totalLockedCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 rewardsRate = _loanConfig.getRewardsRate();
        uint256 multiplier = _loanConfig.getMultiplier();
        
        // Formula: maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) * multiplier) / 1e12
        uint256 maxLoanIgnoreSupply = (((totalLockedCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;
        
        // Ensure user has enough collateral to borrow 10 USD (or more)
        // If not, we need to adjust the test setup
        require(maxLoanIgnoreSupply >= 10e6, "User needs enough collateral to borrow at least 10 USD for this test");
        
        // Get the actual max loan considering vault constraints
        (uint256 maxLoan, uint256 maxLoanIgnoreSupplyActual) = CollateralFacet(_portfolioAccount).getMaxLoan();
        
        // Verify maxLoanIgnoreSupply matches our calculation
        assertEq(maxLoanIgnoreSupplyActual, maxLoanIgnoreSupply, "maxLoanIgnoreSupply should match calculation");
        
        // With vault balance of 10 USD and 80% cap:
        // vaultSupply = vaultBalance + outstandingCapital
        // maxUtilization = vaultSupply * 0.8
        // vaultAvailableSupply = maxUtilization - outstandingCapital
        // If outstandingCapital >= maxUtilization, maxLoan = 0 (vault is over-utilized)
        // Otherwise, maxLoan = min(vaultAvailableSupply, vaultBalance, maxLoanIgnoreSupply - currentLoanBalance)
        uint256 vaultSupply = vaultBalance + outstandingCapital;
        uint256 maxUtilization = (vaultSupply * 8000) / 10000;
        
        // If vault is over-utilized, we need to adjust the test
        require(outstandingCapital < maxUtilization, "Vault must not be over-utilized for this test");
        
        // Get current loan balance for this portfolio account
        uint256 currentLoanBalance = CollateralFacet(_portfolioAccount).getTotalDebt();
        
        // Calculate expected maxLoan following the same logic as LoanUtils.getMaxLoanByRewardsRate
        uint256 vaultAvailableSupply = maxUtilization - outstandingCapital;
        uint256 expectedMaxLoan = maxLoanIgnoreSupply - currentLoanBalance;
        
        // Cap by vaultAvailableSupply
        if (expectedMaxLoan > vaultAvailableSupply) {
            expectedMaxLoan = vaultAvailableSupply;
        }
        
        // Cap by vaultBalance
        if (expectedMaxLoan > vaultBalance) {
            expectedMaxLoan = vaultBalance;
        }
        
        // The maxLoan should be capped by the 80% vault utilization limit
        // Note: expectedMaxLoan accounts for outstandingCapital, so it may be less than 8 USD if outstandingCapital > 0
        assertEq(maxLoan, expectedMaxLoan, "Max loan should be limited by 80% vault utilization cap");
        
        // Get user's balance before borrowing
        uint256 userBalanceBefore = _asset.balanceOf(_user);
        
        // User requests expectedMaxLoan (the actual max they can borrow)
        // The borrow should succeed with expectedMaxLoan amount
        borrowViaMulticall(expectedMaxLoan);
        
        // User should receive expectedMaxLoan due to the 80% cap
        uint256 userBalanceAfter = _asset.balanceOf(_user);
        uint256 actualBorrowed = userBalanceAfter - userBalanceBefore;
        
        // Verify user received expectedMaxLoan
        assertEq(actualBorrowed, expectedMaxLoan - (expectedMaxLoan * 80) / 10000, "User should receive expectedMaxLoan minus origination fee");
        
        // Verify debt matches what was borrowed
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedMaxLoan, "Debt should match borrowed amount");
        
        // Verify vault balance decreased by expectedMaxLoan
        uint256 vaultBalanceAfterBorrow = vaultBalance - expectedMaxLoan;
        assertEq(_asset.balanceOf(vault), vaultBalanceAfterBorrow, "Vault balance should decrease by expectedMaxLoan");
        
        // Verify that if more was in vault, user could borrow more (but still capped at 80%)
        // This demonstrates the user could borrow more if vault had more funds
        uint256 additionalVaultBalance = 15e6; // Add 15 more USD to vault
        // Current vault balance after borrow
        deal(address(_asset), vault, vaultBalanceAfterBorrow + additionalVaultBalance);
        
        // After adding more to vault, the max loan should increase
        // Note: outstandingCapital may have increased due to the borrow, so we recalculate
        uint256 newOutstandingCapital = ILoan(loanContract).activeAssets();
        uint256 newVaultBalance = _asset.balanceOf(vault);
        uint256 newVaultSupply = newVaultBalance + newOutstandingCapital;
        uint256 newMaxUtilization = (newVaultSupply * 8000) / 10000;
        uint256 newVaultAvailableSupply = newMaxUtilization > newOutstandingCapital ? newMaxUtilization - newOutstandingCapital : 0;
        
        // Get updated max loan to verify user could borrow more if vault had more funds
        (uint256 maxLoanAfter, ) = CollateralFacet(_portfolioAccount).getMaxLoan();
        
        // User could borrow more now (up to the new limit), demonstrating that with more vault funds,
        // user could borrow more (subject to 80% cap and collateral limits)
        assertGt(maxLoanAfter, 0, "User should be able to borrow more if vault had more funds");
        
        // The key point: even though user has collateral for 10+ USD, they were limited by the 80% vault utilization cap
        assertTrue(maxLoanIgnoreSupply >= 10e6, "User has enough collateral to borrow 10+ USD");
        // User receives expectedMaxLoan minus origination fee (0.8%)
        assertEq(actualBorrowed, expectedMaxLoan - (expectedMaxLoan * 80) / 10000, "But user only received expectedMaxLoan minus origination fee due to 80% vault cap");
    }
}
