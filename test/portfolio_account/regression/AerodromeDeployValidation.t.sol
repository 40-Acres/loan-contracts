// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {FortyAcresPortfolioAccount} from "../../../src/accounts/FortyAcresPortfolioAccount.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";

/**
 * @title AerodromeDeployValidation
 * @dev Tests that the Aerodrome deployment is structurally correct:
 *      facets, configs, linkage, ownership, registry state.
 */
contract AerodromeDeployValidation is BaseDeploymentSetup {
    // ─── Core contracts deployed ─────────────────────────────────────

    function testCoreContractsDeployed() public view {
        assertTrue(address(portfolioManager) != address(0), "PortfolioManager not deployed");
        assertTrue(address(portfolioFactory) != address(0), "PortfolioFactory not deployed");
        assertTrue(address(facetRegistry) != address(0), "FacetRegistry not deployed");
    }

    // ─── Ownership ───────────────────────────────────────────────────

    function testPortfolioManagerOwnership() public view {
        assertEq(portfolioManager.owner(), DEPLOYER, "PortfolioManager owner should be DEPLOYER");
    }

    function testFacetRegistryOwnership() public view {
        assertEq(facetRegistry.owner(), DEPLOYER, "FacetRegistry owner should be DEPLOYER");
    }

    // ─── Factory registration ────────────────────────────────────────

    function testFactoryRegistered() public view {
        assertTrue(
            portfolioManager.isRegisteredFactory(address(portfolioFactory)),
            "Factory should be registered in PortfolioManager"
        );
    }

    function testFactoryBySalt() public view {
        bytes32 salt = bytes32(keccak256(abi.encodePacked("aerodrome-usdc")));
        assertEq(
            portfolioManager.factoryBySalt(salt),
            address(portfolioFactory),
            "factoryBySalt should return correct factory"
        );
    }

    function testFactoryCount() public view {
        assertEq(portfolioManager.getFactoriesLength(), 1, "Should have exactly 1 factory");
    }

    // ─── Factory ↔ Registry linkage ─────────────────────────────────

    function testFactoryRegistryLinkage() public view {
        assertEq(
            address(portfolioFactory.facetRegistry()),
            address(facetRegistry),
            "Factory should point to correct FacetRegistry"
        );
    }

    function testFactoryManagerLinkage() public view {
        assertEq(
            address(portfolioFactory.portfolioManager()),
            address(portfolioManager),
            "Factory should point to correct PortfolioManager"
        );
    }

    // ─── Facet count ─────────────────────────────────────────────────

    function testFacetCount() public view {
        address[] memory facets = facetRegistry.getAllFacets();
        assertEq(facets.length, 9, "Should have exactly 9 facets registered");
    }

    // ─── Per-facet validation ────────────────────────────────────────

    function testClaimingFacetRegistration() public view {
        _assertFacetRegistered(address(claimingFacet), "ClaimingFacet", 3);
    }

    function testCollateralFacetRegistration() public view {
        _assertFacetRegistered(address(collateralFacet), "CollateralFacet", 10);
    }

    function testLendingFacetRegistration() public view {
        _assertFacetRegistered(address(lendingFacet), "LendingFacet", 5);
    }

    function testVotingFacetRegistration() public view {
        _assertFacetRegistered(address(votingFacet), "VotingFacet", 5);
    }

    function testVotingEscrowFacetRegistration() public view {
        _assertFacetRegistered(address(votingEscrowFacet), "VotingEscrowFacet", 4);
    }

    function testMigrationFacetRegistration() public view {
        _assertFacetRegistered(address(migrationFacet), "MigrationFacet", 1);
    }

    function testMarketplaceFacetRegistration() public view {
        _assertFacetRegistered(address(marketplaceFacet), "MarketplaceFacet", 8);
    }

    function testRewardsProcessingFacetRegistration() public view {
        _assertFacetRegistered(address(rewardsProcessingFacet), "RewardsProcessingFacet", 5);
    }

    // ─── Selector → facet routing ────────────────────────────────────

    function testCollateralSelectorsRouteCorrectly() public view {
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.addCollateral.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.getTotalLockedCollateral.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.getTotalDebt.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.getMaxLoan.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.getOriginTimestamp.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.removeCollateral.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.getCollateralToken.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.enforceCollateralRequirements.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.getLockedCollateral.selector), address(collateralFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseCollateralFacet.removeCollateralTo.selector), address(collateralFacet));
    }

    function testLendingSelectorsRouteCorrectly() public view {
        assertEq(facetRegistry.getFacetForSelector(BaseLendingFacet.borrow.selector), address(lendingFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseLendingFacet.pay.selector), address(lendingFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseLendingFacet.setTopUp.selector), address(lendingFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseLendingFacet.topUp.selector), address(lendingFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseLendingFacet.borrowTo.selector), address(lendingFacet));
    }

    function testMarketplaceSelectorsRouteCorrectly() public view {
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.receiveSaleProceeds.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.makeListing.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.cancelListing.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.marketplace.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.getSaleAuthorization.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.hasSaleAuthorization.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector), address(marketplaceFacet));
    }

    function testRewardsProcessingSelectorsRouteCorrectly() public view {
        assertEq(facetRegistry.getFacetForSelector(RewardsProcessingFacet.processRewards.selector), address(rewardsProcessingFacet));
        assertEq(facetRegistry.getFacetForSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector), facetRegistry.getFacetForSelector(RewardsConfigFacet.setRecipient.selector));
        assertEq(facetRegistry.getFacetForSelector(RewardsConfigFacet.setActiveBalanceDistribution.selector), facetRegistry.getFacetForSelector(RewardsConfigFacet.setRecipient.selector));
    }

    // ─── Registry version ────────────────────────────────────────────

    function testRegistryVersion() public view {
        // Constructor sets version = 1, each registerFacet increments by 1
        // 1 (initial) + 9 (registrations) = 10
        assertEq(facetRegistry.getVersion(), 10, "Registry version should be 10 after 9 registrations");
    }

    // ─── Loan + Vault linkage ────────────────────────────────────────

    function testLoanVaultLinkage() public view {
        assertEq(ILoan(loanContract)._vault(), address(vault), "Loan._vault() should be vault");
    }

    function testLoanAssetLinkage() public view {
        assertEq(ILoan(loanContract)._asset(), USDC, "Loan._asset() should be USDC");
    }

    function testLoanPortfolioFactory() public view {
        assertEq(
            LoanV2(payable(loanContract)).getPortfolioFactory(),
            address(portfolioFactory),
            "LoanV2 should have portfolio factory set"
        );
    }

    // ─── Config linkage ──────────────────────────────────────────────

    function testConfigLoanConfigLinkage() public view {
        assertEq(
            address(portfolioFactoryConfig.getLoanConfig()),
            address(loanConfig),
            "Config should reference correct LoanConfig"
        );
    }

    function testConfigVotingConfigLinkage() public view {
        assertEq(
            portfolioFactoryConfig.getVoteConfig(),
            address(votingConfig),
            "Config should reference correct VotingConfig"
        );
    }

    function testConfigLoanContractLinkage() public view {
        assertEq(
            portfolioFactoryConfig.getLoanContract(),
            loanContract,
            "Config should reference correct Loan contract"
        );
    }

    function testConfigPortfolioFactoryLinkage() public view {
        assertEq(
            portfolioFactoryConfig.getPortfolioFactory(),
            address(portfolioFactory),
            "Config should reference correct PortfolioFactory"
        );
    }

    // ─── CREATE2 determinism ─────────────────────────────────────────

    function testDuplicateFactorySaltReverts() public {
        bytes32 salt = bytes32(keccak256(abi.encodePacked("aerodrome-usdc")));
        vm.prank(DEPLOYER);
        // CREATE2 collision on FacetRegistry happens before salt-reuse check
        vm.expectRevert(abi.encodeWithSelector(PortfolioManager.FacetRegistryDeploymentFailed.selector));
        portfolioManager.deployFactory(salt);
    }

    function testDifferentSaltDifferentFactory() public {
        bytes32 newSalt = bytes32(keccak256(abi.encodePacked("new-salt")));
        vm.prank(DEPLOYER);
        (PortfolioFactory newFactory,) = portfolioManager.deployFactory(newSalt);
        assertTrue(address(newFactory) != address(portfolioFactory), "Different salt should produce different factory");
    }

    // ─── Portfolio account ───────────────────────────────────────────

    function testPortfolioAccountCreated() public view {
        assertTrue(portfolioAccount != address(0), "Portfolio account should be created");
    }

    function testPortfolioAccountRegistered() public view {
        assertTrue(
            portfolioManager.isPortfolioRegistered(portfolioAccount),
            "Portfolio should be registered in manager"
        );
    }

    function testPortfolioAccountOwner() public view {
        assertEq(
            portfolioFactory.ownerOf(portfolioAccount),
            user,
            "Portfolio should be owned by user"
        );
    }

    function testPortfolioAccountRegistry() public view {
        FortyAcresPortfolioAccount account = FortyAcresPortfolioAccount(payable(portfolioAccount));
        assertEq(
            address(account.facetRegistry()),
            address(facetRegistry),
            "Portfolio account should reference correct FacetRegistry"
        );
    }

    function testPortfolioLookupByOwner() public view {
        assertEq(
            portfolioFactory.portfolioOf(user),
            portfolioAccount,
            "portfolioOf(user) should return portfolio account"
        );
    }

    function testPortfolioFactoryTracksPortfolio() public view {
        assertEq(
            portfolioManager.getFactoryForPortfolio(portfolioAccount),
            address(portfolioFactory),
            "Manager should track portfolio -> factory mapping"
        );
    }

    // ─── Internal helpers ────────────────────────────────────────────

    function _assertFacetRegistered(address facet, string memory expectedName, uint256 minSelectorCount) internal view {
        assertTrue(facetRegistry.isFacetRegistered(facet), string.concat(expectedName, " should be registered"));

        bytes4[] memory selectors = facetRegistry.getSelectorsForFacet(facet);
        assertGe(selectors.length, minSelectorCount, string.concat(expectedName, " selector count below minimum"));

        string memory actualName = facetRegistry.getFacetName(facet);
        assertEq(actualName, expectedName, string.concat(expectedName, " name mismatch"));

        // Verify each selector routes back to this facet
        for (uint256 i = 0; i < selectors.length; i++) {
            assertEq(
                facetRegistry.getFacetForSelector(selectors[i]),
                facet,
                string.concat(expectedName, " selector routing mismatch")
            );
        }
    }
}
