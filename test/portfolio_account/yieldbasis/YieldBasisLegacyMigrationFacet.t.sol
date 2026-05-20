// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLegacyMigrationFacet
 *
 * One-shot facet that seeds DynamicYieldBasisCollateralManager.data.shares for
 * accounts whose physical LP / gauge holdings predate the dynamic-manager
 * refactor. Tests cover the full lifecycle the production rehydration script
 * relies on:
 *
 *   - LP-only / gauge-only / mixed seeding paths.
 *   - Natural revert when the account is empty (no custom guard added on top
 *     of the library's `Shares must be > 0` check).
 *   - The `data.shares == 0` replay guard.
 *   - Intentional lack of authorization (any EOA can call once the selector
 *     is registered; safety comes from ephemeral selector lifetime).
 *   - Tracker idempotence -- EnumerableSet.add is a no-op if the account is
 *     already in the per-LP set from a prior era.
 *   - Post-migration: getMaxLoan reflects rehydrated shares, borrow flows
 *     through normally, and withdraw drains the physical LP back to the user.
 *   - Non 1:1 gauge convertToAssets math is honored.
 *
 * Harness: extends DynamicYbDiamond and registers the migration facet inline
 * (one selector, owner-only registry call). The rest of the facets come from
 * the base harness so post-migrate borrow/withdraw can be exercised end to end.
 * =========================================================================*/

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";

import {YieldBasisLegacyMigrationFacet} from
    "../../../src/facets/account/yieldbasislp/YieldBasisLegacyMigrationFacet.sol";
import {DynamicYieldBasisLpFacet} from
    "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisLpLendingFacet} from
    "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpLendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {YieldBasisPortfolioFactoryConfig} from
    "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";

import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

contract YieldBasisLegacyMigrationFacetTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    address internal portfolioAccount;
    YieldBasisLegacyMigrationFacet internal migrationFacet;

    // Mirror of the library event so vm.expectEmit can match on the proxy.
    event YieldBasisCollateralAdded(
        address indexed vault,
        uint256 shares,
        uint256 assetValue,
        address indexed owner
    );

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    function setUp() public {
        _bootstrapTokens();
        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        portfolioAccount = _build(address(gauge), address(lp), address(0));

        // Seed underlying liquidity in the LP so any withdraw-side rebalances
        // can deliver. Not strictly required for the migration calls themselves.
        underlying.mint(address(lp), 1_000_000e18);
        // Mint LP to user so the post-migrate withdraw test can use the same
        // pool of LP (for direct transfer-style seeding).
        lp.mint(user, DEPOSIT * 10);

        _registerMigrationFacet();
    }

    /// @dev Register the one-shot migration facet against the base harness's
    ///      FacetRegistry. Single selector; deployer is `owner_`.
    function _registerMigrationFacet() internal {
        migrationFacet = new YieldBasisLegacyMigrationFacet(
            address(portfolioFactory),
            address(gauge),
            address(lendingVault) // lendingPool used by the base harness
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = YieldBasisLegacyMigrationFacet.migrateYieldBasisCollateral.selector;

        vm.prank(owner_);
        facetRegistry.registerFacet(address(migrationFacet), selectors, "YBLegacyMigration");
    }

    /// @dev Move LP onto the portfolio account directly (no PortfolioManager
    ///      multicall). Mimics the legacy state where the LP token has already
    ///      been transferred to the account but the new manager slot is empty.
    function _seedLpOnAccount(uint256 amount) internal {
        if (amount == 0) return;
        lp.mint(portfolioAccount, amount);
    }

    /// @dev Move gauge shares onto the portfolio account directly. The gauge
    ///      pulls LP via transferFrom under the hood; we use the mock's open
    ///      mint to simulate a pre-existing staked balance without going
    ///      through the gauge's deposit path.
    function _seedGaugeOnAccount(uint256 shares) internal {
        if (shares == 0) return;
        // The mock gauge inherits OpenZeppelin ERC20 with internal _mint; the
        // gauge does not expose a public mint. Use `deal` to write the share
        // balance + totalSupply directly.
        deal(address(gauge), portfolioAccount, shares, true);

        // Also seed the gauge contract with backing LP for any post-migrate
        // withdraw/redeem path that may convert gauge shares back to LP.
        lp.mint(address(gauge), gauge.convertToAssets(shares));
    }

    function _migrateAsCaller(address caller) internal {
        vm.prank(caller);
        YieldBasisLegacyMigrationFacet(portfolioAccount).migrateYieldBasisCollateral();
    }

    // -----------------------------------------------------------------------
    // 1. LP only
    // -----------------------------------------------------------------------

    function test_Migrate_LpOnly() public {
        uint256 n = 100e18;
        _seedLpOnAccount(n);

        // pps defaults to 1e18 -> depositedAssetValue == n.
        uint256 expectedAssetValue = n; // (n * 1e18) / 1e18

        vm.expectEmit(true, true, false, true, portfolioAccount);
        emit YieldBasisCollateralAdded(address(lp), n, expectedAssetValue, portfolioAccount);

        _migrateAsCaller(user);

        // At pps=1e18, getTotalLockedCollateral equals data.shares. That is
        // the only public surface the dynamic manager exposes through the
        // diamond proxy, so it doubles as our share-slot readout.
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            n,
            "collateral mark reflects rehydrated shares (== n at pps=1e18)"
        );
        // Collateral token remains the LP, not the gauge.
        assertEq(
            ICollateralFacet(portfolioAccount).getCollateralToken(),
            address(lp),
            "collateral token is the LP"
        );
    }

    /// @dev Read data.shares via the facet's getTotalLockedCollateral path is
    ///      indirect; expose it via the public getter on the dynamic manager
    ///      library. The library defines it as `external view`, so calling
    ///      through the diamond fallback works: the registry will not find
    ///      the selector unless we register it -- so instead we use a
    ///      different approach: at pps=1e18, getTotalLockedCollateral returns
    ///      exactly `shares`, which is what every assertion in this test
    ///      really wants. We keep this helper for documentation but route
    ///      through the locked-collateral mark.
    function _readCollateralShares() internal view returns (uint256) {
        // At default pps=1e18, shares == locked collateral. All tests in this
        // file are at default pps unless they explicitly change it.
        return ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
    }

    // -----------------------------------------------------------------------
    // 2. Gauge only
    // -----------------------------------------------------------------------

    function test_Migrate_GaugeOnly() public {
        uint256 m = 50e18;
        _seedGaugeOnAccount(m);

        _migrateAsCaller(user);

        // At convertRatioBps=10_000 (1:1), data.shares == m.
        uint256 expected = gauge.convertToAssets(m);
        assertEq(_readCollateralShares(), expected, "shares = gauge.convertToAssets(M)");
        assertEq(expected, m, "1:1 ratio sanity");
    }

    // -----------------------------------------------------------------------
    // 3. Mixed LP + gauge
    // -----------------------------------------------------------------------

    function test_Migrate_Mixed() public {
        uint256 n = 70e18;
        uint256 m = 30e18;
        _seedLpOnAccount(n);
        _seedGaugeOnAccount(m);

        _migrateAsCaller(user);

        uint256 expected = n + gauge.convertToAssets(m);
        assertEq(_readCollateralShares(), expected, "shares = N + convertToAssets(M)");
    }

    // -----------------------------------------------------------------------
    // 4. Empty account -> natural revert from the library
    // -----------------------------------------------------------------------

    function test_Migrate_EmptyAccount_Reverts() public {
        // No LP balance, no gauge balance. Migration's `total = 0` triggers
        // the library's `require(shares > 0, "Shares must be > 0")` -- the
        // intentional natural-revert path. No custom guard sits on top.
        vm.expectRevert(bytes("Shares must be > 0"));
        _migrateAsCaller(user);
    }

    // -----------------------------------------------------------------------
    // 5. Replay guard
    // -----------------------------------------------------------------------

    function test_Migrate_AlreadyMigrated_Reverts() public {
        _seedLpOnAccount(100e18);
        _migrateAsCaller(user);

        // Second call -- data.shares is now non-zero. Replay guard fires.
        vm.expectRevert(bytes("YBLM: already migrated"));
        _migrateAsCaller(user);
    }

    // -----------------------------------------------------------------------
    // 6. No auth -- any caller succeeds
    // -----------------------------------------------------------------------

    function test_Migrate_NoAuth_AnyCallerSucceeds() public {
        _seedLpOnAccount(100e18);

        // A random EOA: not the account owner, not the multisig, not the
        // authorized caller. The facet intentionally has no auth modifier.
        address randomCaller = address(0xC0FFEE);
        _migrateAsCaller(randomCaller);

        assertEq(_readCollateralShares(), 100e18, "random EOA successfully seeded shares");
    }

    // -----------------------------------------------------------------------
    // 7. Tracker notify idempotence
    // -----------------------------------------------------------------------

    function test_Migrate_TrackerNotifyIdempotent() public {
        // Pre-seed the tracker as if the account was registered in a prior era.
        // The collateral hook is gated by `onlyPortfolio`, so prank as the
        // portfolio account itself to add the entry directly.
        vm.prank(portfolioAccount);
        YieldBasisPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .onCollateralAdded(address(lp), 0);

        // Sanity: tracker has exactly one entry for this LP.
        address[] memory before = portfolioFactoryConfig.getAccountsByLp(address(lp));
        assertEq(before.length, 1, "pre-seeded tracker has 1 entry");
        assertEq(before[0], portfolioAccount, "entry is our portfolio account");

        // Migrate. The library notifies onCollateralAdded only when prevShares
        // was 0 (true here), and EnumerableSet.add is a no-op for an existing
        // member -- so we expect the count to stay at 1 with no revert.
        _seedLpOnAccount(50e18);
        _migrateAsCaller(user);

        address[] memory afterMigrate = portfolioFactoryConfig.getAccountsByLp(address(lp));
        assertEq(afterMigrate.length, 1, "tracker still has 1 entry -- no duplicate");
        assertEq(afterMigrate[0], portfolioAccount, "same account");
        assertTrue(
            portfolioFactoryConfig.lpHasAccount(address(lp), portfolioAccount),
            "account remains tracked"
        );
    }

    // -----------------------------------------------------------------------
    // 8. Post-migrate borrow flows
    // -----------------------------------------------------------------------

    function test_PostMigrate_Borrow() public {
        uint256 n = 100e18;
        _seedLpOnAccount(n);
        _migrateAsCaller(user);

        // pps=1e18, ltv=7000 -> maxLoan = n * 7000 / 10000 = 70e18.
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) =
            ICollateralFacet(portfolioAccount).getMaxLoan();
        uint256 expectedMax = (n * LTV_BPS) / 10_000;
        assertEq(maxLoanIgnoreSupply, expectedMax, "ltv view reflects rehydrated shares");
        assertEq(maxLoan, expectedMax, "supply-side abundant -- full headroom available");

        // Borrow well under cap and confirm proceeds + debt.
        uint256 toBorrow = 10e18;
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(
            DynamicYieldBasisLpLendingFacet.borrow.selector, toBorrow
        );
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        assertEq(underlying.balanceOf(user), toBorrow, "user got borrow proceeds");
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            toBorrow,
            "debt reflects fresh borrow against rehydrated collateral"
        );
    }

    // -----------------------------------------------------------------------
    // 9. Post-migrate withdraw drains LP back to owner
    // -----------------------------------------------------------------------

    function test_PostMigrate_Withdraw() public {
        uint256 n = 100e18;
        _seedLpOnAccount(n);
        _migrateAsCaller(user);

        uint256 userLpPre = lp.balanceOf(user);

        // Withdraw everything through the standard facet flow.
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.withdraw.selector, n);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        uint256 userLpPost = lp.balanceOf(user);
        assertEq(userLpPost - userLpPre, n, "owner received all LP back");
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "shares slot drained back to zero"
        );
    }

    // -----------------------------------------------------------------------
    // 10. Gauge convertToAssets math is honored end-to-end
    // -----------------------------------------------------------------------

    function test_Migrate_GaugeConvertToAssets_Math() public {
        // 105% gauge ratio: convertToAssets(100) = 105. Guards against future
        // gauge designs where shares != assets.
        gauge.setConvertRatioBps(10_500);

        uint256 lpDirect = 40e18;
        uint256 gaugeShares = 100e18;
        _seedLpOnAccount(lpDirect);
        _seedGaugeOnAccount(gaugeShares);

        // Expected: 40e18 + convertToAssets(100e18) = 40e18 + 105e18 = 145e18.
        uint256 expectedShares = lpDirect + gauge.convertToAssets(gaugeShares);
        assertEq(expectedShares, 145e18, "ratio sanity (40 + 105)");

        _migrateAsCaller(user);
        assertEq(
            _readCollateralShares(),
            expectedShares,
            "non-1:1 gauge convertToAssets honored in seeded shares"
        );
    }
}
