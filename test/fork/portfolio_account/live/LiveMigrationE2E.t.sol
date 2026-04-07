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
 *      Creates fresh veNFTs and borrows against them on the legacy LoanV2 contract,
 *      then migrates to portfolio accounts.
 *
 *      Run: FOUNDRY_PROFILE=fork forge test --match-path test/fork/portfolio_account/live/LiveMigrationE2E.t.sol --no-match-path 'NONE' -vvv
 */
contract LiveMigrationE2E is LiveDeploymentSetup {
    address public constant MIGRATE_BORROWER = address(uint160(uint256(keccak256("live-migration-borrower"))));

    address public migratePortfolio;
    uint256 public migrateTokenSmall;
    uint256 public migrateTokenLarge;

    /**
     * @dev Override setUp to create fresh veNFTs with legacy debt.
     *      Skips _ensureLoanConfigDefaults so rewardsRate/multiplier stay at 0
     *      for the first test (unconfigured scenario).
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

        // NOTE: intentionally skipping _ensureLoanConfigDefaults()

        // 7. Discover FacetRegistry and owner
        facetRegistry = portfolioFactory.facetRegistry();
        liveOwner = portfolioFactoryConfig.owner();

        // 8. Validate
        if (!portfolioManager.isRegisteredFactory(address(portfolioFactory))) {
            vm.skip(true);
        }
        _validateDiscoveredGraph();

        // 9. Create portfolio for the migration borrower
        migratePortfolio = portfolioFactory.portfolioOf(MIGRATE_BORROWER);
        if (migratePortfolio == address(0)) {
            migratePortfolio = portfolioFactory.createAccount(MIGRATE_BORROWER);
        }

        // 10. Fund vault for any pay operations
        _fundVault(50_000_000e6);

        // 11. Create fresh veNFTs and borrow against them on legacy LoanV2
        _createLegacyLoans();
    }

    function _createLegacyLoans() internal {
        LoanV2 loan = LoanV2(payable(loanContract));

        // Create two veNFTs for the borrower
        deal(AERO, MIGRATE_BORROWER, 200_000e18);
        vm.startPrank(MIGRATE_BORROWER);
        IERC20(AERO).approve(VOTING_ESCROW, 200_000e18);

        // Small lock (1000 AERO) → small debt
        // Lock duration of 26 weeks (well within MAXTIME of 4 years)
        uint256 lockDuration = 26 weeks;
        migrateTokenSmall = IVotingEscrow(VOTING_ESCROW).createLock(1_000e18, lockDuration);
        // Large lock (100000 AERO) → larger debt
        migrateTokenLarge = IVotingEscrow(VOTING_ESCROW).createLock(100_000e18, lockDuration);

        // Approve veNFTs to loan contract (requestLoan will transfer them)
        IVotingEscrow(VOTING_ESCROW).approve(address(loan), migrateTokenSmall);
        IVotingEscrow(VOTING_ESCROW).approve(address(loan), migrateTokenLarge);

        // Request loans with topUp=true to auto-borrow max amount
        loan.requestLoan(migrateTokenSmall, 0, LoanV2.ZeroBalanceOption.DoNothing, 0, address(0), true, false);
        loan.requestLoan(migrateTokenLarge, 0, LoanV2.ZeroBalanceOption.DoNothing, 0, address(0), true, false);
        vm.stopPrank();

        // Verify loans were created
        (uint256 smallBalance,) = loan.getLoanDetails(migrateTokenSmall);
        (uint256 largeBalance,) = loan.getLoanDetails(migrateTokenLarge);
        require(smallBalance > 0, "Small loan should have balance");
        require(largeBalance > 0, "Large loan should have balance");
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
        (uint256 legacyBalance,) = LoanV2(payable(loanContract)).getLoanDetails(migrateTokenSmall);
        assertGt(legacyBalance, 0, "Token should have legacy debt");

        // Verify LoanConfig rates (may or may not be 0 on live chain)
        ILoanConfig loanConfig = ILoanConfig(loanConfigAddr);

        // ── Step 1: Migrate ─────────────────────────────────────────
        vm.prank(MULTISIG);
        LoanV2(payable(loanContract)).migrateToPortfolio(migrateTokenSmall);

        // ── Step 2: Verify debt carried over ────────────────────────
        uint256 portfolioDebt = ICollateralFacet(migratePortfolio).getTotalDebt();
        assertEq(portfolioDebt, legacyBalance, "Portfolio debt should equal legacy balance");

        uint256 collateral = ICollateralFacet(migratePortfolio).getTotalLockedCollateral();
        assertGt(collateral, 0, "Token should be locked as collateral after migration");

        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(migrateTokenSmall),
            migratePortfolio,
            "veNFT should be in portfolio after migration"
        );

        // ── Step 2b: removeCollateral should FAIL (debt > 0) ────────
        {
            address[] memory factories0 = new address[](1);
            factories0[0] = address(portfolioFactory);
            bytes[] memory calls0 = new bytes[](1);
            calls0[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, migrateTokenSmall);

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
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, migrateTokenSmall);

        vm.prank(MIGRATE_BORROWER);
        portfolioManager.multicall(calls, factories);

        assertEq(
            ICollateralFacet(migratePortfolio).getTotalLockedCollateral(),
            0,
            "Collateral should be 0 after removal"
        );

        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(migrateTokenSmall),
            MIGRATE_BORROWER,
            "veNFT should be returned to borrower"
        );
    }

    /**
     * @dev Migration scenario with configured LoanConfig:
     *      1. Migrate token with debt
     *      2. Ensure rewardsRate/multiplier set so maxLoan > 0
     *      3. Attempt removeCollateral — should revert (debt still outstanding)
     *      4. Pay off debt, then withdraw successfully
     */
    function testLive_MigrateWithDebt_ConfiguredRates_CannotWithdrawUntilPaid() public {
        // ── Step 1: Migrate ─────────────────────────────────────────
        (uint256 legacyBalance,) = LoanV2(payable(loanContract)).getLoanDetails(migrateTokenLarge);
        assertGt(legacyBalance, 0, "Token should have legacy debt");

        vm.prank(MULTISIG);
        LoanV2(payable(loanContract)).migrateToPortfolio(migrateTokenLarge);

        uint256 portfolioDebt = ICollateralFacet(migratePortfolio).getTotalDebt();
        assertEq(portfolioDebt, legacyBalance, "Portfolio debt should equal legacy balance");

        // ── Step 2: Configure rates so collateral enforcement is active ──
        //   setRewardsRate can't more than double — reset to 0 first
        ILoanConfig loanConfig = ILoanConfig(loanConfigAddr);
        vm.startPrank(MULTISIG);
        loanConfig.setRewardsRate(0);
        loanConfig.setRewardsRate(10000);
        loanConfig.setMultiplier(0);
        loanConfig.setMultiplier(100);
        vm.stopPrank();

        // Verify maxLoan is now > 0
        (uint256 maxLoan,) = ICollateralFacet(migratePortfolio).getMaxLoan();
        assertGt(maxLoan, 0, "maxLoan should be > 0 with configured rates");

        // ── Step 3: removeCollateral should fail (debt still outstanding) ──
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, migrateTokenLarge);

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
            IVotingEscrow(VOTING_ESCROW).ownerOf(migrateTokenLarge),
            MIGRATE_BORROWER,
            "veNFT should be returned to borrower"
        );
    }
}
