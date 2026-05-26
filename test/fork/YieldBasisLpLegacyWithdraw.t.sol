// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * YieldBasisLpLegacyWithdrawTest -- reproduces a production withdraw revert on
 * the ETH mainnet yb-WETH yieldbasis dynamic-loan portfolio for account
 * 0xF8da84Ca294be8C821b90D952CfC6F455D6961F1.
 *
 * The bug: DynamicYieldBasisLpFacet.withdraw passes the raw tracked
 * `data.shares` value as an asset amount to gauge.withdraw(assets,...). For a
 * legacy account whose gauge ERC4626 balance was minted before vault price
 * drift, the asset-equivalent of those shares is `data.shares - 1 wei` due to
 * floor rounding in convertToAssets, so any request asking for the full
 * tracked share count overshoots gauge.maxWithdraw by exactly 1 wei and the
 * gauge reverts with "erc4626: withdraw more than maximum".
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test \
 *     --match-path test/fork/YieldBasisLpLegacyWithdraw.t.sol -vvv
 *
 * Requires: ETH_RPC_URL env var.
 */

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";
import {IYieldBasisGauge} from "../../src/interfaces/IYieldBasisGauge.sol";
import {DynamicYieldBasisLpFacet} from "../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";

// Minimal local stub -- mirrors DynamicYieldBasisLpFacet.withdraw(uint256)
// without dragging in the full facet (and its imports) for selector encoding.
interface IYbWithdraw {
    function withdraw(uint256 amount) external;
}

// Local stub for gauge ERC4626 views not exposed on the in-repo interface.
interface IERC4626Min {
    function maxWithdraw(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

contract YieldBasisLpLegacyWithdrawTest is Test {
    // ─── Live production addresses (ETH mainnet) ────────────────────────────
    address public constant PORTFOLIO = 0xF8da84Ca294be8C821b90D952CfC6F455D6961F1;
    address public constant OWNER = 0x4c14C31a641273080c78FB08A21b7A195E6AabbD;
    address public constant PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant FACTORY = 0xDef2781c0b9a76C317f74d97a09A1671B1979969;
    address public constant LP_TOKEN = 0x931d40dD07b25B91932b481B63631Ea86d236e09; // yb-WETH
    address public constant GAUGE = 0xe4e656B5215a82009969219b1bAbB7c0757A3315;
    address public constant REWARD_TOKEN = 0x01791F726B4103694969820be083196cC7c045fF; // YB
    address public constant LENDING_POOL = 0xB543dBe91be1D34B5cEe98E8A4366dA7B999e4A1; // yb-WETH supplyVault
    // The deployed DynamicYieldBasisLpFacet bytecode the live diamond routes
    // withdraw() to. The fork test overlays the src/ runtime here so the fix
    // under test actually executes; without the overlay the call would route
    // through the buggy pre-fix bytecode and Test 1 would still revert.
    address public constant LIVE_FACET = 0xf5bDAC775B04c235D6Fd2714c37C4B4F198B1197;

    // keccak256("storage.DynamicYieldBasisCollateralManager")
    bytes32 public constant DYNAMIC_YB_CM_SLOT =
        0xd2ac06a2bbc382d3d424e4f65b6e283bec726a6e80d48b3730365a6766d8c321;

    // Storage layout of DynamicYieldBasisCollateralData:
    //   slot+0 shares
    //   slot+1 depositedAssetValue
    //   slot+2 overSuppliedVaultDebt
    //   slot+3 startShortfall
    //   slot+4 snapshotBlockNumber
    //   slot+5 gauge

    PortfolioManager public portfolioManager;
    IERC20 public lpToken;
    IYieldBasisGauge public gauge;
    IERC4626Min public gauge4626;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 25176870);

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER);
        lpToken = IERC20(LP_TOKEN);
        gauge = IYieldBasisGauge(GAUGE);
        gauge4626 = IERC4626Min(GAUGE);

        _applyFacetUpgrade();

        vm.label(PORTFOLIO, "Portfolio(legacy)");
        vm.label(OWNER, "Owner");
        vm.label(PORTFOLIO_MANAGER, "PortfolioManager");
        vm.label(FACTORY, "Factory(yb-WETH-usdc-loan)");
        vm.label(LP_TOKEN, "yb-WETH-LP");
        vm.label(GAUGE, "yb-WETH-Gauge");
        vm.label(LIVE_FACET, "DynamicYieldBasisLpFacet(etched)");
    }

    /// @dev Production upgrade: deploy new facet with the same constructor
    ///      args, replace bytecode at the diamond's routed facet address.
    function _applyFacetUpgrade() internal {
        DynamicYieldBasisLpFacet newFacet = new DynamicYieldBasisLpFacet(
            FACTORY,
            GAUGE,
            REWARD_TOKEN,
            LENDING_POOL
        );
        vm.etch(LIVE_FACET, address(newFacet).code);
    }

    function _withdrawCalldata(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(IYbWithdraw.withdraw, (amount));
    }

    function _multicall(uint256 amount) internal returns (bytes[] memory) {
        bytes[] memory calls = new bytes[](1);
        calls[0] = _withdrawCalldata(amount);
        address[] memory factories = new address[](1);
        factories[0] = FACTORY;
        return portfolioManager.multicall(calls, factories);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 (post-fix): the production repro now succeeds via facet-level
    // clamping. Requesting 0.45e18 against a legacy account whose tracked
    // shares (0.45e18) exceed gauge.previewRedeem by 1 wei is clamped down to
    // `directLp + convertToAssets(gaugeShares)` -- i.e. 0.45e18 - 1 wei -- and
    // the call goes through. The facet calls `reconcileSharesToBalance` first
    // so `data.gauge` is backfilled from the facet immutable on this legacy
    // account and `data.shares` is ratcheted to actual recoverable LP before
    // any subsequent state mutation.
    // ─────────────────────────────────────────────────────────────────────────
    function test_LegacyAccount_Withdraw45_ClampsToRecoverable() public {
        // Pre-state: legacy storage -- shares=0.45e18, gauge=address(0).
        uint256 sharesBefore = uint256(vm.load(PORTFOLIO, DYNAMIC_YB_CM_SLOT));
        bytes32 gaugeSlotBefore = vm.load(PORTFOLIO, bytes32(uint256(DYNAMIC_YB_CM_SLOT) + 5));
        assertEq(sharesBefore, 0.45e18, "pre-state: data.shares != 0.45e18");
        assertEq(uint256(gaugeSlotBefore), 0, "pre-state: legacy data.gauge must be address(0)");

        uint256 directLpBefore = lpToken.balanceOf(PORTFOLIO);
        uint256 recoverable = gauge4626.maxWithdraw(PORTFOLIO);
        assertEq(directLpBefore, 0, "sanity: legacy portfolio holds no direct LP");
        assertEq(recoverable, 0.45e18 - 1, "sanity: gauge recoverable = 0.45e18 - 1 wei");

        uint256 ownerLpBefore = lpToken.balanceOf(OWNER);

        // No revert -- reconcile-first backfills gauge and ratchets tracked
        // shares, then the drain-all redeem-by-shares path delivers recoverable.
        vm.prank(OWNER);
        _multicall(0.45e18);

        // Owner received exactly the clamped/recoverable amount.
        uint256 ownerLpAfter = lpToken.balanceOf(OWNER);
        uint256 delivered = ownerLpAfter - ownerLpBefore;
        assertEq(delivered, recoverable, "owner must receive exactly convertToAssets(gaugeShares)");

        // data.shares post: reconcile ratchets 0.45e18 down to recoverable,
        // then removeCollateral subtracts toWithdraw (= recoverable). Zero residue.
        uint256 sharesAfter = uint256(vm.load(PORTFOLIO, DYNAMIC_YB_CM_SLOT));
        assertEq(sharesAfter, 0, "data.shares post = 0 (reconcile then full clamped withdraw)");

        // data.gauge backfilled by reconcileSharesToBalance to the canonical
        // facet immutable address.
        bytes32 gaugeSlotAfter = vm.load(PORTFOLIO, bytes32(uint256(DYNAMIC_YB_CM_SLOT) + 5));
        address gaugeFieldAfter = address(uint160(uint256(gaugeSlotAfter)));
        assertEq(gaugeFieldAfter, GAUGE, "data.gauge backfilled to canonical gauge");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: the same call succeeds at 0.449e18 (under the gauge max),
    // demonstrating the bug is a 1-wei rounding mismatch between tracked
    // shares and the gauge's withdrawable asset count.
    // ─────────────────────────────────────────────────────────────────────────
    function test_LegacyAccount_Withdraw449_Succeeds() public {
        uint256 ownerLpBefore = lpToken.balanceOf(OWNER);

        // Pre-state: storage.shares = 0.45e18, gauge field = address(0).
        uint256 sharesBefore = uint256(vm.load(PORTFOLIO, DYNAMIC_YB_CM_SLOT));
        bytes32 gaugeSlotRaw = vm.load(PORTFOLIO, bytes32(uint256(DYNAMIC_YB_CM_SLOT) + 5));
        assertEq(sharesBefore, 0.45e18, "pre-state: data.shares != 0.45e18");
        assertEq(uint256(gaugeSlotRaw), 0, "pre-state: legacy data.gauge must be address(0)");

        vm.prank(OWNER);
        _multicall(0.449e18);

        // Measure precisely -- the gauge could redeliver epsilon less than the
        // requested amount due to ERC4626 floor rounding, but with no YB gauge
        // fee the delivery should be exactly the requested asset count.
        uint256 ownerLpAfter = lpToken.balanceOf(OWNER);
        uint256 delivered = ownerLpAfter - ownerLpBefore;
        assertEq(delivered, 0.449e18, "owner LP balance must increase by exactly 0.449e18");

        // data.shares post: reconcileSharesToBalance backfills data.gauge and
        // ratchets 0.45e18 down to the gauge's recoverable (0.45e18 - 1 wei)
        // first, then removeCollateral subtracts toWithdraw (= 0.449e18).
        // Net: (0.45e18 - 1) - 0.449e18 = 0.001e18 - 1.
        uint256 sharesAfter = uint256(vm.load(PORTFOLIO, DYNAMIC_YB_CM_SLOT));
        assertEq(sharesAfter, 0.001e18 - 1, "data.shares post = 0.001e18 - 1 wei (reconcile then partial decrement)");

        // data.gauge backfilled by reconcileSharesToBalance.
        bytes32 gaugeSlotRawAfter = vm.load(PORTFOLIO, bytes32(uint256(DYNAMIC_YB_CM_SLOT) + 5));
        address gaugeFieldAfter = address(uint160(uint256(gaugeSlotRawAfter)));
        assertEq(gaugeFieldAfter, GAUGE, "data.gauge backfilled to canonical gauge");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: pin the invariant that the planned fix will rely on -- the
    // yb-WETH gauge has no withdraw/redeem fee, so previewRedeem and
    // convertToAssets must agree for the portfolio's actual gauge balance.
    // ─────────────────────────────────────────────────────────────────────────
    function test_GaugePreviewRedeemEqualsConvertToAssets_AtCurrentBlock() public view {
        uint256 shares = gauge4626.balanceOf(PORTFOLIO);
        assertGt(shares, 0, "portfolio must have nonzero gauge balance to pin invariant");

        uint256 preview = gauge4626.previewRedeem(shares);
        uint256 convert = gauge4626.convertToAssets(shares);
        assertEq(preview, convert, "gauge previewRedeem must equal convertToAssets (no fee)");

        // Also lock in that maxWithdraw is exactly convertToAssets(balance) --
        // this is the value the production code overshoots by 1 wei.
        uint256 maxW = gauge4626.maxWithdraw(PORTFOLIO);
        assertEq(maxW, convert, "maxWithdraw must equal convertToAssets(balanceOf)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: pin the legacy-account storage precondition -- raw shares =
    // 0.45e18 and the gauge field has never been written (address(0)).
    // ─────────────────────────────────────────────────────────────────────────
    function test_RawStorage_DataSharesAndGaugeMatchExpectation() public view {
        uint256 shares = uint256(vm.load(PORTFOLIO, DYNAMIC_YB_CM_SLOT));
        assertEq(shares, 0.45e18, "data.shares must equal 0.45e18");

        bytes32 gaugeRaw = vm.load(PORTFOLIO, bytes32(uint256(DYNAMIC_YB_CM_SLOT) + 5));
        address gaugeField = address(uint160(uint256(gaugeRaw)));
        assertEq(gaugeField, address(0), "data.gauge must be address(0) for legacy account");
    }

    // Pre-upgrade reverts; post-upgrade succeeds. Demonstrates that swapping
    // only the facet bytecode (no library, manager, or config redeploy) is
    // sufficient to unblock the legacy account.
    function test_Upgrade_PreReverts_PostSucceeds_FacetOnly() public {
        bytes memory newFacetCode = LIVE_FACET.code;

        // Roll back the setUp etch by re-fetching deployed bytecode.
        uint256 freshFork = vm.createFork(vm.envString("ETH_RPC_URL"), 25176870);
        uint256 prevFork = vm.activeFork();
        vm.selectFork(freshFork);
        bytes memory deployedCode = LIVE_FACET.code;
        vm.selectFork(prevFork);
        vm.etch(LIVE_FACET, deployedCode);

        bytes[] memory calls = new bytes[](1);
        calls[0] = _withdrawCalldata(0.45e18);
        address[] memory factories = new address[](1);
        factories[0] = FACTORY;

        // Pre-upgrade: production repro reverts.
        vm.prank(OWNER);
        try portfolioManager.multicall(calls, factories) {
            assertTrue(false, "pre-upgrade: expected revert");
        } catch Error(string memory reason) {
            assertEq(reason, "erc4626: withdraw more than maximum", "pre-upgrade revert reason mismatch");
        }

        // Apply the upgrade and retry the exact same call.
        vm.etch(LIVE_FACET, newFacetCode);
        uint256 ownerLpBefore = lpToken.balanceOf(OWNER);
        uint256 recoverable = gauge4626.maxWithdraw(PORTFOLIO);
        vm.prank(OWNER);
        portfolioManager.multicall(calls, factories);

        uint256 delivered = lpToken.balanceOf(OWNER) - ownerLpBefore;
        assertEq(delivered, recoverable, "post-upgrade: owner must receive convertToAssets(gaugeShares)");
    }
}
