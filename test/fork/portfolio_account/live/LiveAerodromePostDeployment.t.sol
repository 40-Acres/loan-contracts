// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LiveDeploymentSetup} from "./LiveDeploymentSetup.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";

/**
 * @title LiveAerodromePostDeployment
 * @dev Smoke tests against the live Base deployment. Validates that the actual
 *      deployed contracts work correctly for core operations.
 *
 *      Run: FORGE_PROFILE=fork forge test --match-path test/fork/portfolio_account/live/LiveAerodromePostDeployment.t.sol -vvv
 */
contract LiveAerodromePostDeployment is LiveDeploymentSetup {

    // ─── Collateral ──────────────────────────────────────────────────

    function testLive_AddCollateral() public {
        // setUp already creates a veNFT via createLock, so collateral should be > 0
        uint256 locked = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(locked, 0, "Total locked collateral should be > 0 after setUp createLock");
    }

    function testLive_RemoveCollateral() public {
        uint256 locked = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(locked, 0, "Should have collateral from setUp");

        // Use tokenId captured during setUp's createLock
        _singleMulticallAsUser(
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );

        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "Collateral should be 0 after removal"
        );

        // veNFT should be returned to user
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            user,
            "veNFT should be returned to user after removeCollateral"
        );
    }

    // ─── Borrowing ───────────────────────────────────────────────────

    function testLive_BorrowAgainstCollateral() public {
        uint256 borrowAmount = 1e6; // 1 USDC
        _borrow(borrowAmount);

        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            borrowAmount,
            "Debt should equal borrow amount"
        );
    }

    function testLive_PayBackLoan() public {
        uint256 borrowAmount = 1e6;
        _borrow(borrowAmount);
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), borrowAmount);

        // Fund user with USDC and approve portfolio account
        uint256 totalOwed = borrowAmount + ICollateralFacet(portfolioAccount).getUnpaidFees();
        deal(USDC, user, totalOwed);
        vm.startPrank(user);
        IERC20(USDC).approve(portfolioAccount, totalOwed);
        BaseLendingFacet(portfolioAccount).pay(totalOwed);
        vm.stopPrank();

        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            0,
            "Debt should be 0 after full repayment"
        );
    }

    function testLive_BorrowFailsWithoutCollateral() public {
        // Create a fresh user with no collateral
        address user2 = address(uint160(uint256(keccak256("live-test-no-collateral-user"))));

        // multicall auto-creates account, borrow should fail due to no collateral
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 1e6);

        vm.prank(user2);
        vm.expectRevert();
        portfolioManager.multicall(calls, factories);
    }

    function testLive_BorrowFailsBeyondMaxLoan() public {
        // Try to borrow way more than collateral allows
        vm.expectRevert();
        _borrow(1_000_000e6);
    }

    function testLive_CannotRemoveCollateralWithDebt() public {
        _borrow(1e6);

        // Removing collateral with outstanding debt should revert
        vm.expectRevert();
        _singleMulticallAsUser(
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );
    }

    // ─── View functions ──────────────────────────────────────────────

    function testLive_ViewFunctionsCallable() public view {
        // These should all be callable through the diamond proxy
        uint256 locked = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(locked, 0, "Should have collateral from setUp");

        uint256 debt = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, 0, "No debt initially");

        (, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertGt(maxLoanIgnoreSupply, 0, "maxLoanIgnoreSupply should be > 0 with collateral");

        bool success = ICollateralFacet(portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "enforceCollateralRequirements should return true with no debt");

        address collateralToken = BaseCollateralFacet(portfolioAccount).getCollateralToken();
        assertEq(collateralToken, VOTING_ESCROW, "Collateral token should be VOTING_ESCROW");
    }

    // ─── Second user ─────────────────────────────────────────────────

    function testLive_SecondUserCanCreateAccount() public {
        address user2 = address(uint160(uint256(keccak256("live-test-second-user"))));
        address user2Portfolio = portfolioFactory.createAccount(user2);

        assertTrue(user2Portfolio != address(0), "Second user portfolio should be created");
        assertTrue(user2Portfolio != portfolioAccount, "Second user should get different portfolio");
        assertEq(portfolioFactory.ownerOf(user2Portfolio), user2, "Portfolio owner should be user2");
    }

    // ─── Access control ──────────────────────────────────────────────

    function testLive_DirectBorrowReverts() public {
        // Calling borrow directly (not through multicall) should revert
        // because msg.sender is not the PortfolioManager
        vm.prank(user);
        vm.expectRevert();
        BaseLendingFacet(portfolioAccount).borrow(1e6);
    }

    function testLive_PayIsCallableDirectly() public {
        // pay() does NOT require onlyPortfolioManagerMulticall
        _borrow(1e6);

        // Pay directly (not through multicall)
        deal(USDC, user, 1e6);
        vm.startPrank(user);
        IERC20(USDC).approve(portfolioAccount, 1e6);
        BaseLendingFacet(portfolioAccount).pay(1e6);
        vm.stopPrank();

        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            0,
            "Debt should be 0 after direct pay"
        );
    }
}
