// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

/**
 * @title AerodromePostDeployment
 * @dev Functional smoke tests that verify the deployed system actually works.
 *      All state-changing calls go through _multicallAsUser / _singleMulticallAsUser.
 */
contract AerodromePostDeployment is BaseDeploymentSetup {
    // ─── Collateral ──────────────────────────────────────────────────

    function testAddCollateral() public {
        _addCollateral(tokenId);

        uint256 locked = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(locked, 0, "Total locked collateral should be > 0 after addCollateral");
    }

    function testRemoveCollateral() public {
        _addCollateral(tokenId);
        assertGt(CollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0);

        // Remove collateral
        _singleMulticallAsUser(
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );

        assertEq(CollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "Collateral should be 0 after removal");

        // veNFT should be returned to user
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            user,
            "veNFT should be returned to user after removeCollateral"
        );
    }

    // ─── Borrowing ───────────────────────────────────────────────────

    function testBorrowAgainstCollateral() public {
        _addCollateral(tokenId);
        _fundVault(10e6);

        uint256 borrowAmount = 1e6; // 1 USDC
        _borrow(borrowAmount);

        assertEq(
            CollateralFacet(portfolioAccount).getTotalDebt(),
            borrowAmount,
            "Debt should equal borrow amount"
        );
    }

    function testPayBackLoan() public {
        _addCollateral(tokenId);
        _fundVault(10e6);

        uint256 borrowAmount = 1e6;
        _borrow(borrowAmount);
        assertEq(CollateralFacet(portfolioAccount).getTotalDebt(), borrowAmount);

        // Fund user with USDC and approve portfolio account
        deal(USDC, user, borrowAmount);
        vm.startPrank(user);
        IERC20(USDC).approve(portfolioAccount, borrowAmount);
        LendingFacet(portfolioAccount).pay(borrowAmount);
        vm.stopPrank();

        assertEq(CollateralFacet(portfolioAccount).getTotalDebt(), 0, "Debt should be 0 after full repayment");
    }

    function testBorrowFailsWithoutCollateral() public {
        _fundVault(10e6);

        // No collateral added - borrow should revert
        vm.expectRevert();
        _borrow(1e6);
    }

    function testBorrowFailsBeyondMaxLoan() public {
        _addCollateral(tokenId);
        _fundVault(1_000_000e6);

        // Try to borrow way more than collateral allows
        vm.expectRevert();
        _borrow(1_000_000e6);
    }

    function testCannotRemoveCollateralWithDebt() public {
        _addCollateral(tokenId);
        _fundVault(10e6);
        _borrow(1e6);

        // Removing collateral with outstanding debt should revert
        // (multicall post-check: enforceCollateralRequirements fails)
        vm.expectRevert();
        _singleMulticallAsUser(
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );
    }

    // ─── View functions ──────────────────────────────────────────────

    function testEnforceCollateralRequirementsNoDebt() public view {
        bool success = ICollateralFacet(portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "enforceCollateralRequirements should return true with no debt");
    }

    function testGetMaxLoanNoCollateral() public view {
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "maxLoan should be 0 with no collateral");
        assertEq(maxLoanIgnoreSupply, 0, "maxLoanIgnoreSupply should be 0 with no collateral");
    }

    function testGetMaxLoanWithCollateral() public {
        _addCollateral(tokenId);
        _fundVault(1_000_000e6);

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertGt(maxLoanIgnoreSupply, 0, "maxLoanIgnoreSupply should be > 0 with collateral");
        assertGt(maxLoan, 0, "maxLoan should be > 0 with collateral and funded vault");
    }

    // ─── Diamond proxy delegation ────────────────────────────────────

    function testViewFunctionsCallableDirectly() public view {
        // View functions should work through the diamond proxy fallback
        uint256 locked = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(locked, 0, "No collateral locked initially");

        uint256 debt = CollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, 0, "No debt initially");

        address collateralToken = BaseCollateralFacet(portfolioAccount).getCollateralToken();
        assertEq(collateralToken, VOTING_ESCROW, "Collateral token should be VOTING_ESCROW");
    }

    // ─── Second user ─────────────────────────────────────────────────

    function testSecondUserCanCreateAccount() public {
        address user2 = address(0xbeefdead);
        address user2Portfolio = portfolioFactory.createAccount(user2);

        assertTrue(user2Portfolio != address(0), "Second user portfolio should be created");
        assertTrue(user2Portfolio != portfolioAccount, "Second user should get different portfolio");
        assertEq(portfolioFactory.ownerOf(user2Portfolio), user2, "Portfolio owner should be user2");
    }

    function testDuplicateAccountCreationReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PortfolioFactory.AccountAlreadyExists.selector, user));
        portfolioFactory.createAccount(user);
    }

    // ─── Access control ──────────────────────────────────────────────

    function testDirectAddCollateralReverts() public {
        // Calling addCollateral directly (not through multicall) should revert
        // because msg.sender is not the PortfolioManager
        vm.prank(user);
        vm.expectRevert();
        BaseCollateralFacet(portfolioAccount).addCollateral(tokenId);
    }

    function testDirectBorrowReverts() public {
        vm.prank(user);
        vm.expectRevert();
        BaseLendingFacet(portfolioAccount).borrow(1e6);
    }

    function testPayIsCallableDirectly() public {
        // pay() does NOT require onlyPortfolioManagerMulticall
        // It should be callable by anyone (used by keepers, etc.)
        _addCollateral(tokenId);
        _fundVault(10e6);
        _borrow(1e6);

        // Pay directly (not through multicall)
        deal(USDC, user, 1e6);
        vm.startPrank(user);
        IERC20(USDC).approve(portfolioAccount, 1e6);
        LendingFacet(portfolioAccount).pay(1e6);
        vm.stopPrank();

        assertEq(CollateralFacet(portfolioAccount).getTotalDebt(), 0, "Debt should be 0 after direct pay");
    }
}
