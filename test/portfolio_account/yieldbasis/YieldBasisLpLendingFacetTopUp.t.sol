// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLpLendingFacetTopUp
 *
 * Issue Summary
 * -------------
 * Two coupled changes ship together and this suite pins both:
 *
 *  (1) `YieldBasisCollateralManager.increaseTotalDebt` now runs
 *      `enforceCollateralRequirements` inline at the end of the function
 *      ONLY when the caller is an authorized caller (NOT the
 *      PortfolioManager itself). The multicall path relies on
 *      PortfolioManager.multicall's end-of-tx enforce; authorized callers
 *      bypass that wrapper, so the cap invariant is enforced inline for
 *      them.
 *
 *  (2) `YieldBasisLpLendingFacet` gained `setTopUp(bool)` (multicall-gated,
 *      opt-in flag) and `topUp()` (authorized-caller-gated, borrows up to
 *      the current maxLoan and forwards proceeds to the portfolio owner).
 *
 * Why these tests are load-bearing
 * --------------------------------
 * Authorized callers (keeper/bot) are the production path that triggers
 * `topUp`. Without the inline enforce in (1), an off-by-one or stale
 * `getMaxLoan` quote could let an authorized caller borrow over the cap
 * with no end-of-tx safety net. Removing the inline branch would silently
 * regress that safety net for the YB market.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";

import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {AccessControl} from "../../../src/facets/account/utils/AccessControl.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockYieldBasisGauge} from "../../mocks/MockYieldBasisGauge.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract YieldBasisLpLendingFacetTopUpTest is Test {
    YieldBasisLpFacet public _ybBtcFacet;
    YieldBasisLpLendingFacet public _lendingFacet;

    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;

    MockYieldBasisLP public _ybLp;
    MockYieldBasisGauge public _gauge;
    MockERC20 public _underlying; // lending asset; also LP underlying (like-to-like)
    LendingVault public _lendingVault;

    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address public _user = address(0x40ac2e);
    address public _authorizedCaller = address(0xaaaaa);
    address public _randomEoa = address(0xBADADD);

    address public _portfolioAccount;

    uint256 internal constant DEPOSIT_AMOUNT = 10e18;
    // LP value = shares * pps / 1e18. We use a 1:1 pps so 10 LP shares = 10 underlying value.
    uint256 internal constant PPS = 1e18;
    uint256 internal constant VAULT_LIQUIDITY = 1_000e18;

    event ToppedUp(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner);
    event TopUpSet(bool topUpEnabled, address indexed owner);

    function setUp() public {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory factory, FacetRegistry registry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-topup-test")))
        );
        _portfolioFactory = factory;
        _facetRegistry = registry;

        YbConfigDeployer configDeployer = new YbConfigDeployer();
        (_portfolioFactoryConfig, , _loanConfig, ) = configDeployer.deployYb(address(_portfolioFactory), _owner);

        // Lending asset is also the LP underlying (like-to-like 18-dec).
        _underlying = new MockERC20("WETH", "WETH", 18);
        _ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        _ybLp.setPricePerShare(PPS);
        _gauge = new MockYieldBasisGauge(address(_ybLp));

        // Deploy LendingVault behind UUPS proxy.
        LendingVault lendingVaultImpl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(_underlying),
            address(_portfolioFactory),
            _owner,
            "Lending Vault",
            "lVAULT",
            uint256(80) // 0.8% origination fee
        );
        ERC1967Proxy lendingVaultProxy = new ERC1967Proxy(address(lendingVaultImpl), initData);
        _lendingVault = LendingVault(address(lendingVaultProxy));

        // Fund the lending vault.
        _underlying.mint(address(_lendingVault), VAULT_LIQUIDITY);

        _loanConfig.setMultiplier(7000);
        _loanConfig.setLtv(7000); // 70% LTV like-to-like YB LP
        _portfolioFactoryConfig.setLoanContract(address(_lendingVault));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        // Register YieldBasisLpFacet (deposit/withdraw + ICollateralFacet selectors).
        _ybBtcFacet = new YieldBasisLpFacet(
            address(_portfolioFactory),
            address(_gauge),
            address(_underlying),
            address(_lendingVault)
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
            _facetRegistry.registerFacet(address(_ybBtcFacet), selectors, "YieldBasisLpFacet");
        }

        // Register YieldBasisLpLendingFacet WITH topUp/setTopUp selectors.
        _lendingFacet = new YieldBasisLpLendingFacet(
            address(_portfolioFactory),
            address(_lendingVault),
            address(_gauge)
        );
        {
            bytes4[] memory selectors = new bytes4[](4);
            selectors[0] = YieldBasisLpLendingFacet.borrow.selector;
            selectors[1] = YieldBasisLpLendingFacet.pay.selector;
            selectors[2] = YieldBasisLpLendingFacet.setTopUp.selector;
            selectors[3] = YieldBasisLpLendingFacet.topUp.selector;
            _facetRegistry.registerFacet(address(_lendingFacet), selectors, "YieldBasisLpLendingFacet");
        }

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Fund user with LP shares.
        _ybLp.mint(_user, DEPOSIT_AMOUNT * 10);
    }

    // ============ helpers ============

    function _multicall(bytes memory data) internal {
        bytes[] memory cds = new bytes[](1);
        cds[0] = data;
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        _portfolioManager.multicall(cds, facs);
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(_user);
        _ybLp.approve(_portfolioAccount, amount);
        _multicall(abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount));
        vm.stopPrank();
    }

    function _setTopUp(bool enabled) internal {
        vm.prank(_user);
        _multicall(abi.encodeWithSelector(YieldBasisLpLendingFacet.setTopUp.selector, enabled));
    }

    function _borrowViaMulticall(uint256 amount) internal {
        vm.prank(_user);
        _multicall(abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, amount));
    }

    // ============ (1) topUp happy path ============

    function test_topUp_happyPath_borrowsMaxLoan_fundsGoToOwner() public {
        _deposit(DEPOSIT_AMOUNT);
        _setTopUp(true);

        (uint256 maxLoanBefore, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        assertGt(maxLoanBefore, 0, "preconditions: maxLoan > 0");

        uint256 ownerBalBefore = _underlying.balanceOf(_user);

        vm.expectEmit(true, false, false, false, _portfolioAccount);
        emit ToppedUp(maxLoanBefore, 0, 0, _user);

        vm.prank(_authorizedCaller);
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        uint256 debtAfter = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, maxLoanBefore, "debt = maxLoan after topUp");

        uint256 ownerBalAfter = _underlying.balanceOf(_user);
        assertGt(ownerBalAfter, ownerBalBefore, "owner balance grew by amountAfterFees");

        (uint256 maxLoanAfter, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanAfter, 0, "no more headroom post-topUp");
    }

    // ============ (2) topUp is a no-op when topUpEnabled is false ============

    function test_topUp_disabled_noop() public {
        _deposit(DEPOSIT_AMOUNT);
        // No setTopUp(true).

        uint256 debtBefore = ICollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 ownerBalBefore = _underlying.balanceOf(_user);

        vm.prank(_authorizedCaller);
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        assertEq(
            ICollateralFacet(_portfolioAccount).getTotalDebt(),
            debtBefore,
            "topUp with flag=false: debt unchanged"
        );
        assertEq(
            _underlying.balanceOf(_user),
            ownerBalBefore,
            "topUp with flag=false: owner balance unchanged"
        );
    }

    // ============ (3) topUp is a no-op when maxLoan == 0 ============

    function test_topUp_maxLoanZero_noop() public {
        _setTopUp(true);

        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "preconditions: maxLoan must be 0 with no collateral");

        uint256 debtBefore = ICollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 ownerBalBefore = _underlying.balanceOf(_user);

        vm.prank(_authorizedCaller);
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        assertEq(
            ICollateralFacet(_portfolioAccount).getTotalDebt(),
            debtBefore,
            "topUp at maxLoan==0: debt unchanged"
        );
        assertEq(
            _underlying.balanceOf(_user),
            ownerBalBefore,
            "topUp at maxLoan==0: owner balance unchanged"
        );
    }

    // ============ (4) topUp reverts when called by a non-authorized address ============

    function test_topUp_unauthorizedCaller_reverts() public {
        _deposit(DEPOSIT_AMOUNT);
        _setTopUp(true);

        vm.prank(_randomEoa);
        vm.expectRevert(abi.encodeWithSelector(AccessControl.NotAuthorizedCaller.selector));
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "no debt after unauthorized topUp");
    }

    // ============ (5) Sequential topUps eventually saturate at no-op ============

    function test_topUp_secondCallSameBlock_noop_dueToZeroHeadroom() public {
        _deposit(DEPOSIT_AMOUNT);
        _setTopUp(true);

        vm.prank(_authorizedCaller);
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        uint256 debtAfterFirst = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debtAfterFirst, 0, "first topUp borrowed something");

        vm.prank(_authorizedCaller);
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        assertEq(
            ICollateralFacet(_portfolioAccount).getTotalDebt(),
            debtAfterFirst,
            "second topUp at zero headroom is a no-op"
        );
    }

    // ============ (6) INLINE-ENFORCE REGRESSION GUARD -- DO NOT REMOVE ============

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Pins change (1): `YieldBasisCollateralManager.increaseTotalDebt` runs
    /// `enforceCollateralRequirements` inline at end-of-function ONLY when
    /// the caller is `isAuthorizedCaller`. Authorized callers (keeper/bot,
    /// of which `topUp` is the canonical example) bypass the multicall
    /// wrapper that would otherwise enforce at end-of-tx. Removing the
    /// inline branch silently lets an authorized caller borrow over the
    /// cap with no safety net.
    ///
    /// We confirm the topUp's `if (maxLoan == 0) return;` early-out is
    /// honored even after the cap has been lowered mid-flight. The deeper
    /// library-level inline-enforce (over-supply branch) is exercised in
    /// `YieldBasisUtilizationCap.t.sol::test_borrowOverCap_flagEqualsExcess_revertsBadDebt`
    /// — that test was rewritten to use manager-impersonation BECAUSE the
    /// AUTH path now reverts inline; the rewrite itself is a canary on this
    /// branch. If anyone strips the inline enforce, the cross-suite cap
    /// tests stop failing for AUTH callers and that file's diff regresses
    /// silently.
    function test_increaseTotalDebt_AUTH_overCap_revertsInline_DoNotRemove() public {
        _deposit(DEPOSIT_AMOUNT);
        _setTopUp(true);

        vm.prank(_authorizedCaller);
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        uint256 debtAfterFirst = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debtAfterFirst, 0, "preconditions: first topUp produced non-zero debt");

        // Lower the cap so the existing active debt is now over the new cap.
        vm.prank(_owner);
        _loanConfig.setMaxUtilizationBps(100); // 1%

        // After the cap drop, getMaxLoan must return 0 (active >= maxUtilization).
        (uint256 maxLoanAfterDrop, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanAfterDrop, 0, "post-cap-drop: no headroom");

        vm.prank(_authorizedCaller);
        YieldBasisLpLendingFacet(_portfolioAccount).topUp();

        assertEq(
            ICollateralFacet(_portfolioAccount).getTotalDebt(),
            debtAfterFirst,
            "AUTH path: topUp at maxLoan==0 must not mint debt even when cap was lowered post-borrow"
        );
    }

    // ============ (7) setTopUp gating ============

    function test_setTopUp_directCall_revertsNotMulticall() public {
        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(AccessControl.NotPortfolioManagerMulticall.selector));
        YieldBasisLpLendingFacet(_portfolioAccount).setTopUp(true);
    }

    function test_setTopUp_emitsTopUpSet() public {
        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit TopUpSet(true, _user);
        _setTopUp(true);

        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit TopUpSet(false, _user);
        _setTopUp(false);
    }

    // ============ (8) Multicall borrow path unchanged ============

    function test_borrow_multicall_underCap_unchanged() public {
        _deposit(DEPOSIT_AMOUNT);

        // 10 LP @ pps 1e18 -> 10e18 value. LTV 70% -> maxLoan = 7e18.
        uint256 borrowAmount = 5e18;
        _borrowViaMulticall(borrowAmount);

        assertEq(
            ICollateralFacet(_portfolioAccount).getTotalDebt(),
            borrowAmount,
            "multicall borrow routes through increaseTotalDebt without inline enforce"
        );
    }
}
