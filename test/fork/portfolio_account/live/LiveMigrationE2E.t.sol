// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LiveDeploymentSetup} from "./LiveDeploymentSetup.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {ILoanConfig} from "../../../../src/facets/account/config/ILoanConfig.sol";
import {Loan as LoanV2} from "../../../../src/LoanV2.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiveMigrationE2E
 * @dev Tests migration from legacy LoanV2 to portfolio accounts on the live fork.
 *      Validates that a migrated token with debt cannot be withdrawn until the
 *      loan is fully paid off — especially when LoanConfig is not yet configured
 *      (rewardsRate/multiplier = 0).
 *
 *      Run: FORGE_PROFILE=fork forge test --match-path test/fork/portfolio_account/live/LiveMigrationE2E.t.sol --no-match-path 'NONE' -vvv
 */
contract LiveMigrationE2E is LiveDeploymentSetup {
    // Existing loans on legacy LoanV2 — borrower 0xCB7D87F5...
    uint256 public constant MIGRATE_TOKEN_SMALL = 85477;   // ~0.2 USDC debt
    uint256 public constant MIGRATE_TOKEN_LARGE = 65204;   // ~3090 USDC debt
    address public constant MIGRATE_BORROWER = 0xCB7D87F5502fC91529E0fE92373dDDd8Ff1f3D7c;

    address public migratePortfolio;

    /**
     * @dev Override setUp to skip _ensureLoanConfigDefaults — we want rewardsRate/multiplier = 0
     *      to test the "config not yet set" scenario after migration.
     */
    function setUp() public override {
        // 1. Fork Base at latest block
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        // 2. Bind root contracts
        portfolioManager = PortfolioManager(LIVE_PORTFOLIO_MANAGER);

        // 3. Discover factory from PortfolioManager by salt
        address factoryAddr = portfolioManager.factoryBySalt(AERODROME_USDC_SALT);
        require(factoryAddr != address(0), "LiveSetup: aerodrome-usdc factory not deployed");
        portfolioFactory = PortfolioFactory(factoryAddr);

        // 4. Simulate pending multisig txs (remove once confirmed on-chain)
        _simulatePendingMultisigTx();

        // 5. Discover config from factory
        portfolioFactoryConfig = portfolioFactory.portfolioFactoryConfig();

        // 6. Auto-discover from PortfolioFactoryConfig
        loanContract = portfolioFactoryConfig.getLoanContract();
        loanConfigAddr = address(portfolioFactoryConfig.getLoanConfig());
        votingConfigAddr = portfolioFactoryConfig.getVoteConfig();
        vault = portfolioFactoryConfig.getVault();

        // NOTE: intentionally skipping _ensureLoanConfigDefaults() — rewardsRate/multiplier stay at 0

        // 7. Discover FacetRegistry and owner
        facetRegistry = portfolioFactory.facetRegistry();
        liveOwner = portfolioFactoryConfig.owner();

        // 8. Validate
        if (!portfolioManager.isRegisteredFactory(address(portfolioFactory))) {
            vm.skip(true);
        }
        _validateDiscoveredGraph();

        // 9. Create portfolio for the migration borrower (not the default test user)
        migratePortfolio = portfolioFactory.createAccount(MIGRATE_BORROWER);

        // 10. Fund vault for any pay operations
        _fundVault(50_000_000e6);
    }

    /**
     * @dev Migration scenario with unconfigured LoanConfig (rewardsRate/multiplier = 0):
     *      1. Migrate token with debt from legacy LoanV2 → portfolio
     *      2. Verify debt was carried over and maxLoan = 0
     *      3. Pay off the full debt
     *      4. removeCollateral succeeds — veNFT returned to user
     */
    function testLive_MigrateWithDebt_PayThenWithdraw() public {
        // ── Pre-migration checks ────────────────────────────────────
        (uint256 legacyBalance,) = LoanV2(payable(loanContract)).getLoanDetails(MIGRATE_TOKEN_SMALL);
        assertGt(legacyBalance, 0, "Token should have legacy debt");

        // Verify LoanConfig is unconfigured (rates = 0)
        ILoanConfig loanConfig = ILoanConfig(loanConfigAddr);
        assertEq(loanConfig.getRewardsRate(), 0, "rewardsRate should be 0 (unconfigured)");
        assertEq(loanConfig.getMultiplier(), 0, "multiplier should be 0 (unconfigured)");

        // ── Step 1: Migrate ─────────────────────────────────────────
        vm.prank(MULTISIG);
        LoanV2(payable(loanContract)).migrateToPortfolio(MIGRATE_TOKEN_SMALL);

        // ── Step 2: Verify debt carried over ────────────────────────
        uint256 portfolioDebt = ICollateralFacet(migratePortfolio).getTotalDebt();
        assertEq(portfolioDebt, legacyBalance, "Portfolio debt should equal legacy balance");

        uint256 collateral = ICollateralFacet(migratePortfolio).getTotalLockedCollateral();
        assertGt(collateral, 0, "Token should be locked as collateral after migration");

        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(MIGRATE_TOKEN_SMALL),
            migratePortfolio,
            "veNFT should be in portfolio after migration"
        );

        // maxLoan should be 0 since rewardsRate/multiplier = 0
        (uint256 maxLoan,) = ICollateralFacet(migratePortfolio).getMaxLoan();
        assertEq(maxLoan, 0, "maxLoan should be 0 with unconfigured rates");

        // ── Step 2b: removeCollateral should FAIL (debt > 0, rates unconfigured) ──
        {
            address[] memory factories0 = new address[](1);
            factories0[0] = address(portfolioFactory);
            bytes[] memory calls0 = new bytes[](1);
            calls0[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, MIGRATE_TOKEN_SMALL);

            vm.prank(MIGRATE_BORROWER);
            vm.expectRevert();
            portfolioManager.multicall(calls0, factories0);
        }

        // ── Step 3: Pay off the full debt ───────────────────────────
        deal(USDC, MIGRATE_BORROWER, portfolioDebt);
        vm.startPrank(MIGRATE_BORROWER);
        IERC20(USDC).approve(migratePortfolio, portfolioDebt);
        BaseLendingFacet(migratePortfolio).pay(portfolioDebt);
        vm.stopPrank();

        uint256 debtAfterPay = ICollateralFacet(migratePortfolio).getTotalDebt();
        assertEq(debtAfterPay, 0, "Debt should be 0 after full repayment");

        // ── Step 4: removeCollateral succeeds ───────────────────────
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, MIGRATE_TOKEN_SMALL);

        vm.prank(MIGRATE_BORROWER);
        portfolioManager.multicall(calls, factories);

        assertEq(
            ICollateralFacet(migratePortfolio).getTotalLockedCollateral(),
            0,
            "Collateral should be 0 after removal"
        );

        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(MIGRATE_TOKEN_SMALL),
            MIGRATE_BORROWER,
            "veNFT should be returned to borrower"
        );
    }

    /**
     * @dev Migration scenario with configured LoanConfig:
     *      1. Migrate token with debt
     *      2. Set rewardsRate/multiplier so maxLoan > 0
     *      3. Attempt removeCollateral — should revert (debt > maxLoan delta triggers undercollateralized)
     *      4. Pay off debt, then withdraw successfully
     */
    function testLive_MigrateWithDebt_ConfiguredRates_CannotWithdrawUntilPaid() public {
        // ── Step 1: Migrate ─────────────────────────────────────────
        (uint256 legacyBalance,) = LoanV2(payable(loanContract)).getLoanDetails(MIGRATE_TOKEN_LARGE);
        assertGt(legacyBalance, 0, "Token should have legacy debt");

        vm.prank(MULTISIG);
        LoanV2(payable(loanContract)).migrateToPortfolio(MIGRATE_TOKEN_LARGE);

        uint256 portfolioDebt = ICollateralFacet(migratePortfolio).getTotalDebt();
        assertEq(portfolioDebt, legacyBalance, "Portfolio debt should equal legacy balance");

        // ── Step 2: Configure rates so collateral enforcement is active ──
        ILoanConfig loanConfig = ILoanConfig(loanConfigAddr);
        vm.prank(MULTISIG);
        loanConfig.setRewardsRate(10000);
        vm.prank(MULTISIG);
        loanConfig.setMultiplier(100);

        // Verify maxLoan is now > 0
        (uint256 maxLoan,) = ICollateralFacet(migratePortfolio).getMaxLoan();
        assertGt(maxLoan, 0, "maxLoan should be > 0 with configured rates");

        // ── Step 3: removeCollateral should fail (debt still outstanding) ──
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, MIGRATE_TOKEN_LARGE);

        vm.prank(MIGRATE_BORROWER);
        vm.expectRevert();
        portfolioManager.multicall(calls, factories);

        // ── Step 4: Pay off debt ────────────────────────────────────
        deal(USDC, MIGRATE_BORROWER, portfolioDebt);
        vm.startPrank(MIGRATE_BORROWER);
        IERC20(USDC).approve(migratePortfolio, portfolioDebt);
        BaseLendingFacet(migratePortfolio).pay(portfolioDebt);
        vm.stopPrank();

        assertEq(ICollateralFacet(migratePortfolio).getTotalDebt(), 0, "Debt should be 0");

        // ── Step 5: removeCollateral succeeds ───────────────────────
        vm.prank(MIGRATE_BORROWER);
        portfolioManager.multicall(calls, factories);

        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(MIGRATE_TOKEN_LARGE),
            MIGRATE_BORROWER,
            "veNFT should be returned to borrower"
        );
    }
}
