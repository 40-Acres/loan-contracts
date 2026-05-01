// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLpHarvestMultiAccount — exercises the storage-isolation and
 * order-independence properties of the harvest hard-split when two portfolio
 * accounts share a single diamond.
 *
 * Properties:
 *   P1 — Isolation: A.harvest does not change B's `(shares, deposited, current)`.
 *   P2 — Sum-conservation: harvestedA + harvestedB ≤ totalGrossAvailable.
 *   P3 — Order-independence: A→B vs B→A converges to identical state +/-2 wei.
 *   P4 — Per-account floor: each account's _floor85 is independent.
 *   P5 — Collateral integrity: enforceCollateralRequirements passes for both.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";

import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";
import {HarvestFloor85} from "./helpers/HarvestFloor85.sol";
import {IYieldBasisLP} from "../../../src/interfaces/IYieldBasisLP.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract YieldBasisLpHarvestMultiAccountTest is Test, HarvestFloor85 {
    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    MockTunableYieldBasisLP internal ybLp;
    MockERC20 internal underlying;
    MockERC20 internal ybToken;
    MockTunableYieldBasisGauge internal gauge;

    address internal userA = address(0x1A);
    address internal userB = address(0x1B);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal pA;
    address internal pB;

    uint256 internal constant VAULT_LIQ = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000;

    function setUp() public {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256("multi-account-harvest")
        );
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        underlying = new MockERC20("WETH", "WETH", 18);
        ybLp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        ybToken = new MockERC20("YB", "YB", 18);
        gauge = new MockTunableYieldBasisGauge(address(ybLp));

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(underlying), address(portfolioFactory), owner_, "lvault", "lv", 8000, 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        underlying.mint(address(lendingVault), VAULT_LIQ);

        loanConfig.setMultiplier(LTV_BPS);
        portfolioFactoryConfig.setLoanContract(address(lendingVault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        YieldBasisLpFacet facet = new YieldBasisLpFacet(
            address(portfolioFactory), address(gauge), address(ybToken), address(lendingVault)
        );
        {
            bytes4[] memory selectors = new bytes4[](8);
            selectors[0] = YieldBasisLpFacet.deposit.selector;
            selectors[1] = YieldBasisLpFacet.withdraw.selector;
            selectors[2] = YieldBasisLpFacet.setStakedMode.selector;
            selectors[3] = YieldBasisLpFacet.getStakingState.selector;
            selectors[4] = ICollateralFacet.enforceCollateralRequirements.selector;
            selectors[5] = ICollateralFacet.getTotalLockedCollateral.selector;
            selectors[6] = ICollateralFacet.getTotalDebt.selector;
            selectors[7] = ICollateralFacet.getMaxLoan.selector;
            facetRegistry.registerFacet(address(facet), selectors, "YBFacet");
        }

        YieldBasisLpClaimingFacet claimingFacet = new YieldBasisLpClaimingFacet(
            address(portfolioFactory), address(gauge), address(lendingVault)
        );
        {
            bytes4[] memory selectors = new bytes4[](5);
            selectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
            selectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
            selectors[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
            selectors[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
            selectors[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
            facetRegistry.registerFacet(address(claimingFacet), selectors, "YBClaimingFacet");
        }

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        pA = portfolioFactory.createAccount(userA);
        pB = portfolioFactory.createAccount(userB);

        // Seed underlying liquidity in the LP so harvest's _lpToken.withdraw can deliver.
        underlying.mint(address(ybLp), 1_000_000e18);
    }

    // ============ Helpers ============

    function _deposit(address account, address user, uint256 amount) internal {
        ybLp.mint(user, amount);
        vm.startPrank(user);
        ybLp.approve(account, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _harvest(address account, uint256 minPerShare) internal returns (uint256) {
        vm.prank(authorizedCaller);
        return YieldBasisLpClaimingFacet(account).harvestLpFees(minPerShare);
    }

    function _harvestExpectingNoYield(address account, uint256 minPerShare) internal {
        vm.prank(authorizedCaller);
        try YieldBasisLpClaimingFacet(account).harvestLpFees(minPerShare) returns (uint256) {
            // No-op — succeeded
        } catch {
            // Acceptable: "No yield to harvest" or "Yield too small to harvest"
        }
    }

    function _depositInfo(address account)
        internal
        view
        returns (uint256 shares, uint256 deposited, uint256 current)
    {
        return YieldBasisLpClaimingFacet(account).getDepositInfo();
    }

    function _floorViaLP() internal view returns (uint256) {
        return _floor85(IYieldBasisLP(address(ybLp)));
    }

    /* =====================================================================
     * P1 — Isolation: A's harvest does not change B's tuple.
     * =====================================================================*/
    function testFuzz_Isolation_AHarvestDoesNotMutateB(uint256 lpA, uint256 lpB, uint256 ppsGrowthBps) public {
        lpA = bound(lpA, 1e18, 1e22);
        lpB = bound(lpB, 1e18, 1e22);
        ppsGrowthBps = bound(ppsGrowthBps, 100, 5000);

        _deposit(pA, userA, lpA);
        _deposit(pB, userB, lpB);

        ybLp.setPricePerShare((1e18 * (10_000 + ppsGrowthBps)) / 10_000);

        (uint256 sharesB0, uint256 depB0, uint256 curB0) = _depositInfo(pB);

        uint256 floor = _floorViaLP();
        _harvest(pA, floor);

        (uint256 sharesB1, uint256 depB1, uint256 curB1) = _depositInfo(pB);
        assertEq(sharesB1, sharesB0, "P1: B.shares unchanged by A.harvest");
        assertEq(depB1, depB0, "P1: B.deposited unchanged by A.harvest");
        assertEq(curB1, curB0, "P1: B.current unchanged by A.harvest");
    }

    /* =====================================================================
     * P2 — Sum-conservation: harvestedA + harvestedB ≤ gross available.
     * Gross available = (sharesA + sharesB) × pps − (depositedA + depositedB)
     * (haircut-free upper bound).
     * =====================================================================*/
    function testFuzz_SumConservation(uint256 lpA, uint256 lpB, uint256 ppsGrowthBps) public {
        lpA = bound(lpA, 1e18, 1e22);
        lpB = bound(lpB, 1e18, 1e22);
        ppsGrowthBps = bound(ppsGrowthBps, 100, 5000);

        _deposit(pA, userA, lpA);
        _deposit(pB, userB, lpB);

        uint256 newPps = (1e18 * (10_000 + ppsGrowthBps)) / 10_000;
        ybLp.setPricePerShare(newPps);

        (uint256 sharesA, uint256 depA, ) = _depositInfo(pA);
        (uint256 sharesB, uint256 depB, ) = _depositInfo(pB);
        uint256 grossAvailable = ((sharesA + sharesB) * newPps) / 1e18 - (depA + depB);

        uint256 floor = _floorViaLP();
        uint256 receivedA = _harvest(pA, floor);
        uint256 receivedB = _harvest(pB, floor);

        // Allow a 4-wei tolerance for compound integer-division rounding.
        assertLe(receivedA + receivedB, grossAvailable + 4, "P2: combined harvest <= gross + dust");
    }

    /* =====================================================================
     * P3 — Order-independence: A→B vs B→A produces identical final tuples.
     * Implementation: replay the test in two snapshots and compare end-states.
     * =====================================================================*/
    function testFuzz_OrderIndependence(uint256 lpA, uint256 lpB, uint256 ppsGrowthBps) public {
        lpA = bound(lpA, 1e18, 1e22);
        lpB = bound(lpB, 1e18, 1e22);
        ppsGrowthBps = bound(ppsGrowthBps, 100, 5000);

        _deposit(pA, userA, lpA);
        _deposit(pB, userB, lpB);
        ybLp.setPricePerShare((1e18 * (10_000 + ppsGrowthBps)) / 10_000);

        uint256 floor = _floorViaLP();

        uint256 snap = vm.snapshotState();

        // Order A→B
        _harvest(pA, floor);
        _harvest(pB, floor);
        (uint256 sA1, uint256 dA1, ) = _depositInfo(pA);
        (uint256 sB1, uint256 dB1, ) = _depositInfo(pB);

        vm.revertToState(snap);

        // Order B→A
        _harvest(pB, floor);
        _harvest(pA, floor);
        (uint256 sA2, uint256 dA2, ) = _depositInfo(pA);
        (uint256 sB2, uint256 dB2, ) = _depositInfo(pB);

        assertApproxEqAbs(sA2, sA1, 2, "P3: shares A converge +/-2 wei across order");
        assertApproxEqAbs(sB2, sB1, 2, "P3: shares B converge +/-2 wei across order");
        assertApproxEqAbs(dA2, dA1, 2, "P3: deposited A converge +/-2 wei across order");
        assertApproxEqAbs(dB2, dB1, 2, "P3: deposited B converge +/-2 wei across order");
    }

    /* =====================================================================
     * P4 — Per-account floor: A's harvest with its own floor doesn't bleed
     * into B's floor check. (Independence of vm.prank(authorizedCaller)
     * across separate calls — sanity check.)
     * =====================================================================*/
    function test_PerAccountFloorIndependence() public {
        _deposit(pA, userA, 100e18);
        _deposit(pB, userB, 100e18);
        ybLp.setPricePerShare(1.10e18);

        uint256 floorAOk = _floorViaLP();         // 85% of pps — passes
        uint256 floorBTooLow = (1.10e18 * 84) / 100; // 84% — should revert

        // A succeeds.
        uint256 receivedA = _harvest(pA, floorAOk);
        assertGt(receivedA, 0, "P4: A succeeds at 85% floor");

        // B independently fails the floor; A is unaffected.
        vm.prank(authorizedCaller);
        vm.expectRevert("Slippage floor < 85%");
        YieldBasisLpClaimingFacet(pB).harvestLpFees(floorBTooLow);
    }

    /* =====================================================================
     * P5 — Collateral integrity: post-harvest both accounts pass enforce.
     * =====================================================================*/
    function testFuzz_CollateralIntegrityBoth(uint256 lpA, uint256 lpB, uint256 ppsGrowthBps) public {
        lpA = bound(lpA, 1e18, 1e22);
        lpB = bound(lpB, 1e18, 1e22);
        ppsGrowthBps = bound(ppsGrowthBps, 100, 5000);

        _deposit(pA, userA, lpA);
        _deposit(pB, userB, lpB);
        ybLp.setPricePerShare((1e18 * (10_000 + ppsGrowthBps)) / 10_000);

        uint256 floor = _floorViaLP();
        _harvest(pA, floor);
        _harvest(pB, floor);

        assertTrue(ICollateralFacet(pA).enforceCollateralRequirements(), "P5: A enforce ok");
        assertTrue(ICollateralFacet(pB).enforceCollateralRequirements(), "P5: B enforce ok");
    }
}
