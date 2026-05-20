// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {YieldBasisPortfolioFactoryConfig} from
    "../../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {YieldBasisLegacyMigrationFacet} from
    "../../../../src/facets/account/yieldbasislp/YieldBasisLegacyMigrationFacet.sol";
import {IYieldBasisGauge} from "../../../../src/interfaces/IYieldBasisGauge.sol";
import {IYieldBasisLP} from "../../../../src/interfaces/IYieldBasisLP.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";

/**
 * @title LiveYbLegacyMigration
 * @dev Fork test against ETH mainnet that exercises YieldBasisLegacyMigrationFacet
 *      against the real production portfolio account
 *      0xF8da84Ca294be8C821b90D952CfC6F455D6961F1.
 *
 *      State at fork time:
 *        - Account holds 0.45 yb-WETH LP physically
 *        - getTotalLockedCollateral() returns 0 (Dynamic manager slot empty)
 *        - Zero debt against the current loan contract
 *        - Not present in YieldBasisPortfolioFactoryConfig.getAccountsByLp(lp)
 *
 *      The migration should rehydrate the account's shares slot from physical
 *      balance, stamp depositedAssetValue from pricePerShare, fire the tracker
 *      notify hook, and emit the standard YieldBasisCollateralAdded event.
 *      After deregister the migrate selector must be unreachable on the
 *      diamond.
 *
 *      Run:
 *        FOUNDRY_PROFILE=fork forge test --match-contract LiveYbLegacyMigration -vv
 */
contract LiveYbLegacyMigration is Test {
    // Production mainnet wiring.
    address public constant LEGACY_ACCOUNT = 0xF8da84Ca294be8C821b90D952CfC6F455D6961F1;
    address public constant PORTFOLIO_FACTORY = 0xDef2781c0b9a76C317f74d97a09A1671B1979969;
    address public constant CONFIG = 0x8706FD061241266959e6A6E9e084f34935087012;
    address public constant FACET_REGISTRY = 0xCF8d230f7D81141F12E8f8a4f8dc70327b29e0af;
    address public constant LP = 0x931d40dD07b25B91932b481B63631Ea86d236e09;
    address public constant GAUGE = 0xe4e656B5215a82009969219b1bAbB7c0757A3315;
    address public constant LOAN_CONTRACT = 0xB543dBe91be1D34B5cEe98E8A4366dA7B999e4A1;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    address public constant LOAN_CONFIG = 0xF0bD3142BdFe8458F41D3513fb91eeDC9aF1C661;

    PortfolioFactory portfolioFactory = PortfolioFactory(PORTFOLIO_FACTORY);
    FacetRegistry facetRegistry = FacetRegistry(FACET_REGISTRY);
    YieldBasisPortfolioFactoryConfig config = YieldBasisPortfolioFactoryConfig(CONFIG);
    IYieldBasisLP lp = IYieldBasisLP(LP);
    IYieldBasisGauge gauge = IYieldBasisGauge(GAUGE);

    YieldBasisLegacyMigrationFacet migrationFacet;
    bytes4 migrateSelector;
    bytes4[] selectors;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // Sanity checks against the live state. If any of these fail the fork
        // has drifted and the test setup needs adjusting before re-running.
        assertEq(facetRegistry.owner(), MULTISIG, "registry owner drifted");
        assertEq(address(portfolioFactory.facetRegistry()), FACET_REGISTRY, "registry binding drifted");
        assertEq(address(portfolioFactory.portfolioFactoryConfig()), CONFIG, "config binding drifted");
        assertEq(IYieldBasisGauge(GAUGE).asset(), LP, "gauge asset drifted");

        migrationFacet = new YieldBasisLegacyMigrationFacet(PORTFOLIO_FACTORY, GAUGE, LOAN_CONTRACT);
        migrateSelector = YieldBasisLegacyMigrationFacet.migrateYieldBasisCollateral.selector;
        selectors.push(migrateSelector);

        // The deployed LoanConfig impl predates getLtv() and
        // getMaxUtilizationBps(), which the current
        // DynamicYieldBasisCollateralManager snapshot path calls. The
        // production Safe batch deploys a fresh LoanConfig impl, upgrades
        // via UUPS, flips the market to the like-to-like LTV path, and
        // disables the cash-flow multiplier in a single atomic batch.
        // Mirror that sequence here so the fork test exercises the same
        // shape the multisig will sign.
        LoanConfig newLoanConfigImpl = new LoanConfig();
        vm.startPrank(MULTISIG);
        (bool ok,) = LOAN_CONFIG.call(
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newLoanConfigImpl), bytes(""))
        );
        require(ok, "LoanConfig upgrade failed");
        LoanConfig(LOAN_CONFIG).setLtv(LTV_BPS);
        LoanConfig(LOAN_CONFIG).setMultiplier(0);
        vm.stopPrank();
    }

    uint256 public constant LTV_BPS = 1100;

    function _registerMigrationFacet() internal {
        vm.prank(MULTISIG);
        facetRegistry.registerFacet(address(migrationFacet), selectors, "YieldBasisLegacyMigrationFacet");
    }

    function _removeMigrationFacet() internal {
        vm.prank(MULTISIG);
        facetRegistry.removeFacet(address(migrationFacet));
    }

    function _callMigrate(address account) internal {
        (bool ok, bytes memory ret) = account.call(abi.encodeWithSelector(migrateSelector));
        require(ok, string(abi.encodePacked("migrate failed: ", ret)));
    }

    function _expectedShares(address account) internal view returns (uint256) {
        uint256 lpBal = IERC20(LP).balanceOf(account);
        uint256 gaugeBal = IERC20(GAUGE).balanceOf(account);
        if (gaugeBal == 0) return lpBal;
        return lpBal + gauge.convertToAssets(gaugeBal);
    }

    function _expectedDepositedAssetValue(uint256 shares) internal view returns (uint256) {
        return (shares * lp.pricePerShare()) / 1e18;
    }

    function test_Fork_LiveStateBaseline() public view {
        assertGt(IERC20(LP).balanceOf(LEGACY_ACCOUNT), 0, "account must hold LP at fork time");
        assertEq(ICollateralFacet(LEGACY_ACCOUNT).getTotalLockedCollateral(), 0, "slot must be empty pre-migrate");
        assertEq(ICollateralFacet(LEGACY_ACCOUNT).getTotalDebt(), 0, "no debt expected at fork time");
        assertFalse(config.lpHasAccount(LP, LEGACY_ACCOUNT), "account must not be tracked pre-migrate");
        assertEq(
            facetRegistry.getFacetForSelector(migrateSelector),
            address(0),
            "migrate selector must be unregistered pre-batch"
        );
    }

    function test_Fork_LoanConfigUpgradeRestoredMissingMethods() public view {
        // Post-setUp the upgrade has been applied and the like-to-like
        // path has been activated. Both reads must succeed and reflect
        // the new configuration; multiplier is zeroed so the cash-flow
        // branch is unreachable from here on.
        assertEq(LoanConfig(LOAN_CONFIG).getLtv(), LTV_BPS, "ltv must equal target after setLtv");
        assertEq(LoanConfig(LOAN_CONFIG).getMultiplier(), 0, "multiplier must be zeroed");
        assertGt(
            LoanConfig(LOAN_CONFIG).getMaxUtilizationBps(),
            0,
            "default max-utilization must apply when slot is zero"
        );
    }

    function test_Fork_RehydrateLegacyAccount() public {
        uint256 lpBalBefore = IERC20(LP).balanceOf(LEGACY_ACCOUNT);
        uint256 gaugeBalBefore = IERC20(GAUGE).balanceOf(LEGACY_ACCOUNT);
        uint256 expectedShares = _expectedShares(LEGACY_ACCOUNT);
        uint256 expectedValue = _expectedDepositedAssetValue(expectedShares);
        assertGt(expectedShares, 0, "expected shares must be non-zero");

        _registerMigrationFacet();
        assertEq(facetRegistry.getFacetForSelector(migrateSelector), address(migrationFacet));

        _callMigrate(LEGACY_ACCOUNT);

        // Physical balances unchanged: no transfers occur during migration.
        assertEq(IERC20(LP).balanceOf(LEGACY_ACCOUNT), lpBalBefore, "LP balance must not move");
        assertEq(IERC20(GAUGE).balanceOf(LEGACY_ACCOUNT), gaugeBalBefore, "gauge balance must not move");

        // Locked collateral now reflects rehydrated shares.
        uint256 lockedAfter = ICollateralFacet(LEGACY_ACCOUNT).getTotalLockedCollateral();
        assertGt(lockedAfter, 0, "locked collateral must be populated post-migrate");

        // depositedAssetValue stamp matches a fresh deposit of the same shares.
        // getTotalLockedCollateral uses min(EMA fair value, withdrawable), so it
        // may equal or be below the pricePerShare-based deposit stamp. Lower
        // bound: withdrawable >= shares only when pps >= 1; just assert the
        // mark is in a sane range relative to the basis stamp.
        assertLe(lockedAfter, expectedValue, "locked must not exceed basis stamp");

        // Tracker hook fired: account is now enumerable for this LP.
        assertTrue(config.lpHasAccount(LP, LEGACY_ACCOUNT), "account must be in tracker post-migrate");
        address[] memory tracked = config.getAccountsByLp(LP);
        bool found;
        for (uint256 i = 0; i < tracked.length; i++) {
            if (tracked[i] == LEGACY_ACCOUNT) {
                found = true;
                break;
            }
        }
        assertTrue(found, "legacy account must appear in getAccountsByLp");

        // Debt remained zero through the migration.
        assertEq(ICollateralFacet(LEGACY_ACCOUNT).getTotalDebt(), 0, "debt must remain zero");

        _removeMigrationFacet();
        assertEq(
            facetRegistry.getFacetForSelector(migrateSelector), address(0), "migrate selector must be unregistered"
        );

        // Direct call to the migrate selector now reverts at the diamond
        // fallback (require facet != 0).
        (bool ok,) = LEGACY_ACCOUNT.call(abi.encodeWithSelector(migrateSelector));
        assertFalse(ok, "post-remove migrate call must revert");

        console.log("=== Rehydration summary ===");
        console.log("Account:         ", LEGACY_ACCOUNT);
        console.log("LP balance:      ", lpBalBefore);
        console.log("Gauge balance:   ", gaugeBalBefore);
        console.log("Rehydrated shares:", expectedShares);
        console.log("Locked collateral:", lockedAfter);
        console.log("Basis stamp:     ", expectedValue);
    }

    function test_Fork_ReplayGuard() public {
        _registerMigrationFacet();
        _callMigrate(LEGACY_ACCOUNT);

        // Second call on the same account must revert with the replay guard,
        // independent of any token balance changes. The selector stays live
        // through the assertion to isolate the replay path.
        (bool ok, bytes memory ret) =
            LEGACY_ACCOUNT.call(abi.encodeWithSelector(migrateSelector));
        assertFalse(ok, "replay must revert");
        assertEq(_decodeRevertReason(ret), "YBLM: already migrated", "wrong revert reason");

        _removeMigrationFacet();
    }

    function test_Fork_AnyCallerCanInvoke() public {
        _registerMigrationFacet();

        // No auth modifier: a random EOA can drive the call. This mirrors the
        // production threat model where safety derives from atomicity of the
        // Safe multiSend, not from a per-call permission check.
        address randomCaller = address(uint160(uint256(keccak256("randomCaller"))));
        vm.prank(randomCaller);
        (bool ok,) = LEGACY_ACCOUNT.call(abi.encodeWithSelector(migrateSelector));
        assertTrue(ok, "no-auth call must succeed when selector is registered");

        assertGt(
            ICollateralFacet(LEGACY_ACCOUNT).getTotalLockedCollateral(),
            0,
            "post-call collateral must be populated"
        );

        _removeMigrationFacet();
    }

    function _decodeRevertReason(bytes memory data) internal pure returns (string memory) {
        if (data.length < 68) return "";
        assembly {
            data := add(data, 0x04)
        }
        return abi.decode(data, (string));
    }
}
