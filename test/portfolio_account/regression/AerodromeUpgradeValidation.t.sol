// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";

/**
 * @title AerodromeUpgradeValidation
 * @dev Tests that facet replacement and loan upgrades preserve state
 *      and that unauthorized upgrades revert.
 */
contract AerodromeUpgradeValidation is BaseDeploymentSetup {
    // ─── Facet replacement ───────────────────────────────────────────

    function testReplaceFacetUpdatesRegistry() public {
        address oldFacet = address(collateralFacet);
        uint256 versionBefore = facetRegistry.getVersion();

        // Deploy a new CollateralFacet with same constructor args
        CollateralFacet newCollateralFacet = new CollateralFacet(
            address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW
        );

        // Build the same 11 selectors
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = BaseCollateralFacet.addCollateral.selector;
        selectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        selectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        selectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        selectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        selectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        selectors[6] = BaseCollateralFacet.removeCollateral.selector;
        selectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        selectors[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        selectors[9] = BaseCollateralFacet.getLockedCollateral.selector;
        selectors[10] = BaseCollateralFacet.removeCollateralTo.selector;

        vm.prank(DEPLOYER);
        facetRegistry.replaceFacet(oldFacet, address(newCollateralFacet), selectors, "CollateralFacet");

        // Selectors should point to new facet
        assertEq(
            facetRegistry.getFacetForSelector(BaseCollateralFacet.addCollateral.selector),
            address(newCollateralFacet),
            "Selectors should route to new facet"
        );

        // Version should increment
        assertEq(facetRegistry.getVersion(), versionBefore + 1, "Version should increment after replacement");

        // Old facet should be deregistered
        assertFalse(facetRegistry.isFacetRegistered(oldFacet), "Old facet should be deregistered");

        // New facet should be registered
        assertTrue(facetRegistry.isFacetRegistered(address(newCollateralFacet)), "New facet should be registered");
    }

    // ─── State preservation after facet replace ──────────────────────

    function testStatePreservedAfterFacetReplace() public {
        // Add collateral first
        _addCollateral(tokenId);
        uint256 lockedBefore = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(lockedBefore, 0, "Should have locked collateral");

        // Replace CollateralFacet
        CollateralFacet newCollateralFacet = new CollateralFacet(
            address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW
        );

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = BaseCollateralFacet.addCollateral.selector;
        selectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        selectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        selectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        selectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        selectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        selectors[6] = BaseCollateralFacet.removeCollateral.selector;
        selectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        selectors[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        selectors[9] = BaseCollateralFacet.getLockedCollateral.selector;
        selectors[10] = BaseCollateralFacet.removeCollateralTo.selector;

        vm.prank(DEPLOYER);
        facetRegistry.replaceFacet(address(collateralFacet), address(newCollateralFacet), selectors, "CollateralFacet");

        // State should be preserved (diamond storage lives in the account, not the facet)
        uint256 lockedAfter = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(lockedAfter, lockedBefore, "Locked collateral should be unchanged after facet replacement");
    }

    // ─── Loan upgrade preserves state ────────────────────────────────

    function testLoanUpgradePreservesDebt() public {
        _addCollateral(tokenId);
        _fundVault(10e6);
        _borrow(1e6);

        uint256 debtBefore = CollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtBefore, 1e6, "Debt should be 1 USDC");

        // Upgrade loan implementation
        LoanV2 newLoanImpl = new LoanV2();
        vm.prank(DEPLOYER);
        LoanV2(payable(loanContract)).upgradeToAndCall(address(newLoanImpl), new bytes(0));

        // Debt should be unchanged
        uint256 debtAfter = CollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, debtBefore, "Debt should be unchanged after loan upgrade");
    }

    // ─── Unauthorized upgrades revert ────────────────────────────────

    function testUnauthorizedReplaceFacetReverts() public {
        address nonOwner = address(0xdead);
        CollateralFacet newFacet = new CollateralFacet(
            address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = BaseCollateralFacet.addCollateral.selector;

        vm.prank(nonOwner);
        vm.expectRevert();
        facetRegistry.replaceFacet(address(collateralFacet), address(newFacet), selectors, "CollateralFacet");
    }

    function testUnauthorizedLoanUpgradeReverts() public {
        address nonOwner = address(0xdead);
        LoanV2 newLoanImpl = new LoanV2();

        vm.prank(nonOwner);
        vm.expectRevert();
        LoanV2(payable(loanContract)).upgradeToAndCall(address(newLoanImpl), new bytes(0));
    }
}
