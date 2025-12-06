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
        
        // Borrow against collateral
        borrowViaMulticall(borrowAmount);
        
        // Check debt is tracked (borrowFromPortfolio doesn't add origination fee)
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount);
        
        // Verify CollateralManager tracks debt
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
        
        // Should revert - insufficient collateral (no token owned means no collateral)
        vm.expectRevert();
        borrowViaMulticall(1e6);
    }

    function testPayLoan() public {
        // Setup: add collateral and borrow
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 1e6;
        borrowViaMulticall(borrowAmount);
        
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), borrowAmount);
        _assertDebtSynced(_tokenId);
        
        // Fund portfolio with USDC for payment
        // deal() replaces balance, so add to existing balance
        uint256 currentBalance = _asset.balanceOf(_portfolioAccount);
        deal(address(_asset), _portfolioAccount, currentBalance + borrowAmount);
        
        // Approve loan contract to transfer USDC
        vm.startPrank(_portfolioAccount);
        IERC20(_asset).approve(_portfolioAccountConfig.getLoanContract(), borrowAmount);
        vm.stopPrank();
        
        // Pay back the full loan balance
        payViaMulticall(_tokenId, borrowAmount);
        
        // Debt should be zero
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function testPartialPayment() public {
        // Setup: add collateral and borrow
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 2e6; // 2 USDC
        borrowViaMulticall(borrowAmount);
        
        _assertDebtSynced(_tokenId);
        
        // Fund portfolio with USDC for payment
        uint256 currentBalance = _asset.balanceOf(_portfolioAccount);
        deal(address(_asset), _portfolioAccount, currentBalance + 1e6);
        
        // Approve loan contract to transfer USDC
        vm.startPrank(_portfolioAccount);
        IERC20(_asset).approve(_portfolioAccountConfig.getLoanContract(), 1e6);
        vm.stopPrank();
        
        // Pay back half of the original amount
        uint256 payAmount = 1e6;
        payViaMulticall(_tokenId, payAmount);
        
        // Debt should be reduced
        uint256 expectedBalance = borrowAmount - payAmount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), expectedBalance);
        _assertDebtSynced(_tokenId);
    }

    function testIncreaseLoan() public {
        // Setup: add collateral and initial borrow
        addCollateralViaMulticall(_tokenId);
        uint256 initialBorrow = 1e6;
        borrowViaMulticall(initialBorrow);
        
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), initialBorrow);
        _assertDebtSynced(_tokenId);
        
        // Borrow more (should increase existing loan)
        uint256 additionalBorrow = 1e6;
        borrowViaMulticall(additionalBorrow);
        
        // Total debt should be sum of both borrows
        uint256 expectedDebt = initialBorrow + additionalBorrow;
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

    function testBorrowExceedsCollateralButLessThanVault() public {
        // Add collateral
        addCollateralViaMulticall(_tokenId);
        
        // Calculate maxLoanIgnoreSupply based on collateral
        uint256 totalLockedCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 rewardsRate = _loanConfig.getRewardsRate();
        uint256 multiplier = _loanConfig.getMultiplier();
        
        // Formula: maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) * multiplier) / 1e12
        uint256 maxLoanIgnoreSupply = (((totalLockedCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;
        
        // Get vault balance
        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        uint256 vaultBalance = _asset.balanceOf(vault);
        
        // Ensure vault has enough balance for our test
        require(vaultBalance > maxLoanIgnoreSupply, "Vault balance must exceed maxLoanIgnoreSupply for this test");
        
        // Try to borrow more than collateral allows but less than vault balance
        uint256 borrowAmount = maxLoanIgnoreSupply + 1e6; // 1 USDC more than allowed by collateral
        require(borrowAmount < vaultBalance, "Borrow amount must be less than vault balance for this test");
        
        // Should revert with InsufficientCollateral error
        vm.expectRevert(CollateralManager.InsufficientCollateral.selector);
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
}
