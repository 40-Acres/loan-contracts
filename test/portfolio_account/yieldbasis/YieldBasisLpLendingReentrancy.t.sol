// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLpLendingReentrancy -- verifies the (to-be-added) `nonReentrant`
 * guard on the NON-DYNAMIC YieldBasisLpLendingFacet.pay().
 *
 * pay() is directly callable by any user (the `from = msg.sender` branch) and
 * pulls the lending token via safeTransferFrom BEFORE decreaseTotalDebt -- the
 * reentrancy seat. The dynamic sibling DynamicYieldBasisLpLendingFacet.pay()
 * IS guarded; the non-dynamic one currently is NOT.
 *
 * Production asset is USDC (no transfer hook), so there's no live exploit;
 * these are defense-in-depth tests for a future callback-capable asset. We
 * simulate the callback asset with MockReentrantERC20 wired in as the LENDING
 * token (pay pulls the lending token, not the LP collateral).
 *
 * After the fix, the outer pay() sets the shared lending-reentrancy slot and
 * the re-entrant inner pay() reverts with ReentrantCall(). The parameterless
 * custom error has the same 4-byte selector regardless of which contract
 * declares it, so we assert against YieldBasisLpClaimingFacet.ReentrantCall
 * (already importable; the lending facet does not declare the error yet).
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
import {MockReentrantERC20} from "../../mocks/MockReentrantERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockYieldBasisGauge} from "../../mocks/MockYieldBasisGauge.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract YieldBasisLpLendingReentrancyTest is Test {
    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    // Lending token is a callback-capable mock (ERC777-style reentry surface).
    MockReentrantERC20 internal lendingToken;
    // YB reward token (unused by the pay path; needed by the LP facet ctor).
    MockERC20 internal ybToken;
    // Collateral LP token (a plain, well-behaved LP).
    MockYieldBasisLP internal ybLp;
    MockYieldBasisGauge internal gauge;

    YieldBasisLpFacet internal ybFacet;
    YieldBasisLpClaimingFacet internal claimingFacet;
    YieldBasisLpLendingFacet internal lendingFacet;

    address internal portfolioAccount;

    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 internal constant DEPOSIT = 100e18;     // LP collateral (18-dec, pps 1e18)
    uint256 internal constant VAULT_LIQ = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000;       // 70%
    uint256 internal constant BORROW_AMOUNT = 50e18;

    function setUp() public {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) =
            portfolioManager.deployFactory(keccak256("yb-lending-reentrancy"));
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        // Lending token = callback-capable mock. The LendingVault asset is THIS,
        // so YieldBasisLpLendingFacet._lendingToken resolves to it.
        lendingToken = new MockReentrantERC20("Callback USD", "cUSD", 18);
        ybToken = new MockERC20("YieldBasis", "YB", 18);
        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18); // pps defaults to 1e18
        gauge = new MockYieldBasisGauge(address(ybLp));

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(lendingToken), address(portfolioFactory), owner_, "lvault", "lv", 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        lendingToken.mint(address(lendingVault), VAULT_LIQ);

        // LTV branch requires lendingAsset == underlying; both derive from the
        // vault asset (lendingToken) by construction in the facet ctor.
        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS);
        portfolioFactoryConfig.setLoanContract(address(lendingVault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Register YieldBasisLpFacet (deposit + ICollateralFacet views).
        ybFacet = new YieldBasisLpFacet(
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
            facetRegistry.registerFacet(address(ybFacet), selectors, "YBFacet");
        }

        // Register claiming facet (declares the shared ReentrantCall error/slot).
        claimingFacet = new YieldBasisLpClaimingFacet(
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

        // Register the NON-DYNAMIC lending facet so pay() is reachable.
        lendingFacet = new YieldBasisLpLendingFacet(
            address(portfolioFactory), address(lendingVault), address(gauge)
        );
        {
            bytes4[] memory selectors = new bytes4[](4);
            selectors[0] = YieldBasisLpLendingFacet.borrow.selector;
            selectors[1] = YieldBasisLpLendingFacet.pay.selector;
            selectors[2] = YieldBasisLpLendingFacet.setTopUp.selector;
            selectors[3] = YieldBasisLpLendingFacet.topUp.selector;
            facetRegistry.registerFacet(address(lendingFacet), selectors, "YBLendingFacet");
        }

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        // Fund user with LP and deposit it as collateral (unstaked, default mode).
        ybLp.mint(user, DEPOSIT * 10);
        _depositCollateral(DEPOSIT);

        // Borrow so debt > 0 (required for pay() to do real work).
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, BORROW_AMOUNT);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            BORROW_AMOUNT,
            "setUp: debt should equal borrow amount"
        );
    }

    function _depositCollateral(uint256 amount) internal {
        vm.startPrank(user);
        ybLp.approve(portfolioAccount, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    /* =====================================================================
     * NEGATIVE TEST (expected to FAIL on current unguarded code):
     * arm the lending token to re-enter pay() during the transferFrom pull.
     *
     * Post-fix: outer pay() sets the lending-reentrancy slot; inner pay()
     * observes status==2 and reverts ReentrantCall(), which the mock bubbles.
     * Current code: pay() is unguarded, so the re-entry succeeds and no revert
     * occurs -- expectRevert then fails ("call did not revert as expected").
     * =====================================================================*/
    function test_Pay_Reentrancy_IntoPay_Reverts() public {
        uint256 payAmount = 10e18;
        // User funds + approves the outer pay() pull.
        lendingToken.mint(user, payAmount);
        vm.prank(user);
        lendingToken.approve(portfolioAccount, type(uint256).max);

        // The re-entrant inner pay() runs with msg.sender == the token contract
        // (it originates the callback), so `from` in pay() resolves to the token.
        // Fund + approve the token so the inner pull SUCCEEDS cleanly on current
        // unguarded code -- the outer pay then returns normally and
        // expectRevert(ReentrantCall) fails with "call did not revert as
        // expected", the right-reason failure (no guard present, reentry not
        // blocked). Post-fix the outer pay sets the slot and the inner pay
        // reverts ReentrantCall() before the pull.
        uint256 innerAmount = 1e18;
        lendingToken.mint(address(lendingToken), innerAmount);
        vm.prank(address(lendingToken));
        lendingToken.approve(portfolioAccount, type(uint256).max);

        // Arm: during the outer pay()'s transferFrom pull, re-enter pay().
        bytes memory reentrantCall =
            abi.encodeWithSelector(YieldBasisLpLendingFacet.pay.selector, innerAmount);
        lendingToken.arm(portfolioAccount, reentrantCall);

        vm.prank(user);
        vm.expectRevert(YieldBasisLpClaimingFacet.ReentrantCall.selector);
        YieldBasisLpLendingFacet(portfolioAccount).pay(payAmount);
    }

    /* =====================================================================
     * NEGATIVE TEST variant: re-enter harvestLpFees (which already shares the
     * same lending-reentrancy slot) during pay()'s transferFrom pull. Post-fix
     * the guard set by pay() must trip harvest's identical guard.
     *
     * harvestLpFees is onlyAuthorizedCaller; to observe the reentrancy guard in
     * isolation we authorize the lending token. We don't need harvest to do real
     * work -- the guard check runs at the top of the modifier, before any state.
     * Current code: pay() does not set the slot, so the inner harvest proceeds
     * to its own body and reverts for an unrelated reason (no yield), NOT with
     * ReentrantCall -- expectRevert(ReentrantCall) therefore fails on current
     * code, confirming the guard is absent.
     * =====================================================================*/
    function test_Pay_Reentrancy_IntoHarvest_Reverts() public {
        uint256 payAmount = 10e18;
        lendingToken.mint(user, payAmount * 2);

        // Authorize the lending token so its inner harvest call clears the
        // access-control gate and we measure the reentrancy guard.
        vm.prank(owner_);
        portfolioManager.setAuthorizedCaller(address(lendingToken), true);

        // A non-zero, >=85%-of-pps slippage floor so harvest passes its arg
        // checks and reaches the guard / body. pps = 1e18, underlying 18-dec.
        uint256 floor = (1e18 * 90) / 100;
        bytes memory reentrantCall =
            abi.encodeWithSelector(YieldBasisLpClaimingFacet.harvestLpFees.selector, floor);
        lendingToken.arm(portfolioAccount, reentrantCall);

        vm.startPrank(user);
        lendingToken.approve(portfolioAccount, type(uint256).max);
        vm.expectRevert(YieldBasisLpClaimingFacet.ReentrantCall.selector);
        YieldBasisLpLendingFacet(portfolioAccount).pay(payAmount);
        vm.stopPrank();
    }

    /* =====================================================================
     * POSITIVE CONTROL (must pass on current AND fixed code):
     * a normal pay() with the (un-armed) lending token succeeds and reduces
     * debt. Ensures the guard fix is not a tautology -- the happy path must
     * keep working after the modifier is added.
     * =====================================================================*/
    function test_Pay_NormalRepayment_ReducesDebt() public {
        uint256 payAmount = 20e18;
        lendingToken.mint(user, payAmount);

        uint256 debtBefore = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "control: starting debt");

        vm.startPrank(user);
        lendingToken.approve(portfolioAccount, payAmount);
        // Token is NOT armed -> no reentry; behaves as a plain ERC20.
        uint256 excess = YieldBasisLpLendingFacet(portfolioAccount).pay(payAmount);
        vm.stopPrank();

        uint256 debtAfter = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(excess, 0, "control: no excess for a partial repay");
        assertEq(debtAfter, debtBefore - payAmount, "control: debt reduced by exact payment");
    }
}
