// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLpClaimingNativeDecimals
 *
 * Locks in the units convention for the YieldBasis LP claiming-facet views:
 *   getDepositInfo()      -> (shares, depositedUnderlyingValue, currentUnderlyingValue)
 *   getAvailableLpFeeYield() -> (yieldUnderlying, yieldGaugeShares)
 *
 * The collateral managers stamp basis/current value at 18 decimals
 * (shares * pricePerShare() / 1e18, and pricePerShare is always 18d). The
 * ERC4626 claiming views return value fields in the UNDERLYING token's NATIVE
 * decimals. These YieldBasis views must match: the *value* fields
 * (depositedUnderlyingValue, currentUnderlyingValue, yieldUnderlying) must be
 * denormalized from 18d to the underlying's native decimals.
 *
 * The SHARE-count fields (getDepositInfo.shares, getAvailableLpFeeYield.
 * yieldGaugeShares) are LP/gauge share counts and must NOT be rescaled.
 *
 * Because denormalization is the identity for an 18-decimal underlying (WETH),
 * an 18d test cannot distinguish before/after the fix. So the failing
 * assertions here use an 8-decimal underlying (cbBTC-like): an 18d basis value
 * of X*1e18 must surface as X*1e8. On the CURRENT (unfixed) code the views
 * return the raw 18d value, so the native-scaled assertions fail by ~1e10x.
 *
 * An 18d control contract documents that the fix is decimals-aware (identity
 * at 18d), not a blanket rescale.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";

import {DynamicYieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpClaimingFacet.sol";

import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ---------------------------------------------------------------------------
 * DYNAMIC variant: reuse the shared DynamicYbDiamond builder unmodified.
 *
 * The harness's _bootstrapTokens() hardcodes an 18d underlying. We do NOT call
 * it; instead we set `underlying`/`ybToken` directly with the decimals we want
 * before calling _build(). _build() only ever reads the `underlying` state
 * var, so an 8d token flows through the LendingVault + facet construction
 * cleanly. No change to the shared harness.
 * ------------------------------------------------------------------------- */
contract DynamicYbClaimingNativeDecimalsTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    address internal account;

    uint8 internal constant DEC = 8;

    function setUp() public {
        // 8-decimal underlying (cbBTC-like) instead of the harness's 18d WETH.
        underlying = new MockERC20("cbBTC", "cbBTC", DEC);
        ybToken = new MockERC20("YB", "YB", 18);

        lp = new MockTunableYieldBasisLP("ybBTC", "ybBTC", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        account = _build(address(gauge), address(lp), address(0));

        // Seed enough native-decimal underlying inside the LP to satisfy any
        // withdraw, and give the user LP shares to deposit.
        underlying.mint(address(lp), 1_000_000e8);
        lp.mint(user, DEPOSIT * 10);
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(user);
        lp.approve(account, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    // DEPOSIT = 100e18 LP shares, pps default 1e18.
    //   depositedAssetValue (18d) = 100e18 * 1e18 / 1e18 = 100e18.
    // After pps -> 1.10e18:
    //   currentAssetValue (18d)  = min(100e18 * 1.10, withdrawable_rescaled) = 110e18.
    // Native (8d) expectations after the fix:
    //   deposited = 100e8 ; current = 110e8.
    function test_getDepositInfo_returnsNativeUnderlyingDecimals() public {
        _deposit(DEPOSIT);
        lp.setPricePerShare(1.10e18);

        (uint256 shares, uint256 deposited, uint256 current) =
            DynamicYieldBasisLpClaimingFacet(account).getDepositInfo();

        // shares is a share count: must be unchanged (NOT denormalized).
        assertEq(shares, DEPOSIT, "shares unchanged (share count)");

        // value fields must be native (8d) scale, not 18d.
        assertEq(deposited, 100e8, "depositedUnderlyingValue native (8d)");
        assertEq(current, 110e8, "currentUnderlyingValue native (8d)");
    }

    // yieldUnderlying (18d) = current(110e18) - deposited(100e18) = 10e18.
    // Native (8d) after the fix: 10e8.
    // yieldGaugeShares is a share count: 100e18 * 10e18 / 110e18 ~= 9.0909e18.
    function test_getAvailableLpFeeYield_returnsNativeUnderlyingDecimals() public {
        _deposit(DEPOSIT);
        lp.setPricePerShare(1.10e18);

        (uint256 yieldUnderlying, uint256 yieldGaugeShares) =
            DynamicYieldBasisLpClaimingFacet(account).getAvailableLpFeeYield();

        // value field must be native (8d) scale.
        assertEq(yieldUnderlying, 10e8, "yieldUnderlying native (8d)");

        // share-count field is unchanged (still 18d-scaled share count).
        // 100e18 * 10e18 / 110e18 = 9_090_909_090_909_090_909 (floor).
        assertEq(yieldGaugeShares, 9_090_909_090_909_090_909, "yieldGaugeShares is a share count, unchanged");
    }
}

/* ---------------------------------------------------------------------------
 * DYNAMIC 18d control: identity. Documents the fix is decimals-aware.
 * ------------------------------------------------------------------------- */
contract DynamicYbClaiming18dControlTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    address internal account;

    function setUp() public {
        underlying = new MockERC20("WETH", "WETH", 18);
        ybToken = new MockERC20("YB", "YB", 18);

        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        account = _build(address(gauge), address(lp), address(0));

        underlying.mint(address(lp), 1_000_000e18);
        lp.mint(user, DEPOSIT * 10);
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(user);
        lp.approve(account, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    // At 18d underlying the denormalization is the identity -- values stay 18d.
    function test_18dUnderlying_valuesUnchangedIdentity() public {
        _deposit(DEPOSIT);
        lp.setPricePerShare(1.10e18);

        (uint256 shares, uint256 deposited, uint256 current) =
            DynamicYieldBasisLpClaimingFacet(account).getDepositInfo();
        assertEq(shares, DEPOSIT, "shares unchanged");
        assertEq(deposited, 100e18, "deposited stays 18d");
        assertEq(current, 110e18, "current stays 18d");

        (uint256 yieldUnderlying,) =
            DynamicYieldBasisLpClaimingFacet(account).getAvailableLpFeeYield();
        assertEq(yieldUnderlying, 10e18, "yieldUnderlying stays 18d");
    }
}

/* ---------------------------------------------------------------------------
 * NON-DYNAMIC variant: the regular YieldBasisLpClaimingFacet has no shared
 * abstract harness, so build the diamond inline (mirrors the HardSplit setUp)
 * against an 8d underlying.
 * ------------------------------------------------------------------------- */
contract YbClaimingNativeDecimalsTest is Test {
    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    MockERC20 internal underlying;
    MockERC20 internal ybToken;
    MockTunableYieldBasisLP internal ybLp;
    MockTunableYieldBasisGauge internal gauge;

    YieldBasisLpFacet internal facet;
    YieldBasisLpClaimingFacet internal claimingFacet;
    YieldBasisLpLendingFacet internal lendingFacet;

    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal account;

    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant VAULT_LIQ = 10_000_000e8; // 8d underlying
    uint256 internal constant LTV_BPS = 7000;
    uint8 internal constant DEC = 8;

    function setUp() public {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) =
            portfolioManager.deployFactory(keccak256("yb-native-decimals"));
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        underlying = new MockERC20("cbBTC", "cbBTC", DEC);
        ybToken = new MockERC20("YB", "YB", 18);
        ybLp = new MockTunableYieldBasisLP("ybBTC", "ybBTC", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(ybLp));

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(underlying), address(portfolioFactory), owner_, "lvault", "lv", 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        underlying.mint(address(lendingVault), VAULT_LIQ);

        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS);
        portfolioFactoryConfig.setLoanContract(address(lendingVault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        facet = new YieldBasisLpFacet(
            address(portfolioFactory), address(gauge), address(ybToken), address(lendingVault)
        );
        {
            bytes4[] memory s = new bytes4[](8);
            s[0] = YieldBasisLpFacet.deposit.selector;
            s[1] = YieldBasisLpFacet.withdraw.selector;
            s[2] = YieldBasisLpFacet.setStakedMode.selector;
            s[3] = YieldBasisLpFacet.getStakingState.selector;
            s[4] = ICollateralFacet.enforceCollateralRequirements.selector;
            s[5] = ICollateralFacet.getTotalLockedCollateral.selector;
            s[6] = ICollateralFacet.getTotalDebt.selector;
            s[7] = ICollateralFacet.getMaxLoan.selector;
            facetRegistry.registerFacet(address(facet), s, "YBFacet");
        }

        claimingFacet = new YieldBasisLpClaimingFacet(
            address(portfolioFactory), address(gauge), address(lendingVault)
        );
        {
            bytes4[] memory s = new bytes4[](5);
            s[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
            s[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
            s[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
            s[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
            s[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
            facetRegistry.registerFacet(address(claimingFacet), s, "YBClaimingFacet");
        }

        lendingFacet = new YieldBasisLpLendingFacet(
            address(portfolioFactory), address(lendingVault), address(gauge)
        );
        {
            bytes4[] memory s = new bytes4[](2);
            s[0] = YieldBasisLpLendingFacet.borrow.selector;
            s[1] = YieldBasisLpLendingFacet.pay.selector;
            facetRegistry.registerFacet(address(lendingFacet), s, "YBLendingFacet");
        }

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        account = portfolioFactory.createAccount(user);

        ybLp.mint(user, DEPOSIT * 10);
        underlying.mint(address(ybLp), 1_000_000e8);
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(user);
        ybLp.approve(account, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function test_getDepositInfo_returnsNativeUnderlyingDecimals() public {
        _deposit(DEPOSIT);
        ybLp.setPricePerShare(1.10e18);

        (uint256 shares, uint256 deposited, uint256 current) =
            YieldBasisLpClaimingFacet(account).getDepositInfo();

        assertEq(shares, DEPOSIT, "shares unchanged (share count)");
        assertEq(deposited, 100e8, "depositedUnderlyingValue native (8d)");
        assertEq(current, 110e8, "currentUnderlyingValue native (8d)");
    }

    function test_getAvailableLpFeeYield_returnsNativeUnderlyingDecimals() public {
        _deposit(DEPOSIT);
        ybLp.setPricePerShare(1.10e18);

        (uint256 yieldUnderlying, uint256 yieldGaugeShares) =
            YieldBasisLpClaimingFacet(account).getAvailableLpFeeYield();

        assertEq(yieldUnderlying, 10e8, "yieldUnderlying native (8d)");
        assertEq(yieldGaugeShares, 9_090_909_090_909_090_909, "yieldGaugeShares is a share count, unchanged");
    }
}
