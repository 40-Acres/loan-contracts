// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

/**
 * @title AerodromePostDeployment
 * @dev Zero-state functional smoke tests that verify the deployed system works
 *      without requiring real veNFT collateral. Tests that need collateral
 *      (addCollateral, borrow, pay, etc.) remain in the fork suite.
 */
contract AerodromePostDeployment is BaseDeploymentSetup {
    function setUp() public override {
        super.setUp();
        // getMaxLoan() calls vault.totalAssets() → USDC.balanceOf() which needs a mock locally
        vm.mockCall(USDC, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
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
}
