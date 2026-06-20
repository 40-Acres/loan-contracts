// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * DynamicYieldBasisLpRewardsProcessing
 *
 * Verifies the new RewardsProcessingFacet variant's WIRING:
 *  - _getTotalDebt routes through DynamicYieldBasisCollateralManager.getTotalDebt
 *    (live read, no cache).
 *  - _decreaseTotalDebt routes through the dynamic manager's decreaseTotalDebt.
 *  - _getLoanUtilization routes through the dynamic manager.
 *  - _isSwapAllowed blocks both the LP token and the gauge as input tokens.
 *
 * The internal methods are exposed via a thin shim subclass so the test can
 * call them directly. The shim uses the exact same constructor wiring as the
 * production facet -- no behavioral divergence.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";

import {DynamicYieldBasisLpRewardsProcessingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpRewardsProcessingFacet.sol";
import {DynamicYieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Public-exposure shim. Identical constructor wiring. Exposes the
///      internal overrides so unit tests can assert their behavior directly.
contract DYBRewardsShim is DynamicYieldBasisLpRewardsProcessingFacet {
    constructor(
        address portfolioFactory,
        address swapConfig,
        address gauge,
        address vault,
        address defaultToken,
        address underlying
    ) DynamicYieldBasisLpRewardsProcessingFacet(
        portfolioFactory, swapConfig, gauge, vault, defaultToken, underlying
    ) {}

    function exposedGetTotalDebt() external view returns (uint256) {
        return _getTotalDebt();
    }
    function exposedDecreaseTotalDebt(uint256 amount) external returns (uint256) {
        return _decreaseTotalDebt(amount);
    }
    function exposedGetLoanUtilization() external view returns (uint256) {
        return _getLoanUtilization();
    }
    function exposedIsSwapAllowed(address inputToken) external view returns (bool) {
        return _isSwapAllowed(inputToken);
    }
}

/// @dev Minimal lending pool that lets the test set debt + utilization
///      values independently. Mirrors the dynamic-manager interface contract.
contract MockPoolForRewards {
    address public immutable _asset;
    address public immutable _vaultSelf;
    address internal _portfolioFactory;
    uint256 public _rawDebt;
    uint256 public _activeAssets;

    constructor(address asset_, address pf_) {
        _asset = asset_;
        _vaultSelf = address(this);
        _portfolioFactory = pf_;
    }

    function setRaw(uint256 v) external { _rawDebt = v; }
    function setActiveAssets(uint256 v) external { _activeAssets = v; }

    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function lendingAsset() external view returns (address) { return _asset; }
    function lendingVault() external view returns (address) { return _vaultSelf; }
    function activeAssets() external view returns (uint256) { return _activeAssets; }
    function activeAssetsConservative() external view returns (uint256) { return _activeAssets; }
    function asset() external view returns (address) { return _asset; }
    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this)) + _activeAssets;
    }
    function borrowFromPortfolio(uint256) external pure returns (uint256) { return 0; }
    function payFromPortfolio(uint256 amount, uint256) external returns (uint256 paid) {
        paid = amount > _rawDebt ? _rawDebt : amount;
        if (paid > 0) IERC20(_asset).transferFrom(msg.sender, address(this), paid);
        _rawDebt -= paid;
    }
    function getDebtBalance(address) external view returns (uint256) { return _rawDebt; }
    function getEffectiveDebtBalance(address) external view returns (uint256) { return _rawDebt; }
    function depositRewards(uint256) external {}
}

contract DynamicYieldBasisLpRewardsProcessingTest is Test {
    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    SwapConfig internal swapConfig;
    LendingVault internal lendingVault;
    MockPoolForRewards internal pool;

    MockERC20 internal underlying;
    MockERC20 internal defaultToken;
    MockERC20 internal someOtherToken;
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;

    DYBRewardsShim internal shim;
    address internal portfolioAccount;

    address internal user = address(0x40ac2e);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal authorizedCaller = address(0xaaaaa);

    function setUp() public {
        vm.startPrank(owner_);

        // Tokens.
        underlying = new MockERC20("WETH", "WETH", 18);
        defaultToken = new MockERC20("DEFAULT", "DEFAULT", 18);
        someOtherToken = new MockERC20("OTHER", "OTHER", 18);

        // Portfolio infra.
        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(keccak256("dyb-rewards-test"));
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, swapConfig) = deployer.deployYb(address(portfolioFactory), owner_);

        // Mock pool stands in for the dynamic vault so we can freely stage
        // raw debt / activeAssets without going through borrow flows.
        pool = new MockPoolForRewards(address(underlying), address(portfolioFactory));
        underlying.mint(address(pool), 1_000_000e18);

        loanConfig.setMultiplier(7000);
        loanConfig.setLtv(7000);
        portfolioFactoryConfig.setLoanContract(address(pool));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // LP + gauge.
        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        underlying.mint(address(lp), 1_000_000e18);

        // Shim facet -- mirrors the dynamic rewards-processing constructor.
        shim = new DYBRewardsShim(
            address(portfolioFactory),
            address(swapConfig),
            address(gauge),
            address(pool),       // vault
            address(defaultToken),
            address(underlying)
        );
        {
            bytes4[] memory selectors = new bytes4[](4);
            selectors[0] = DYBRewardsShim.exposedGetTotalDebt.selector;
            selectors[1] = DYBRewardsShim.exposedDecreaseTotalDebt.selector;
            selectors[2] = DYBRewardsShim.exposedGetLoanUtilization.selector;
            selectors[3] = DYBRewardsShim.exposedIsSwapAllowed.selector;
            facetRegistry.registerFacet(address(shim), selectors, "DYBRewardsShim");
        }

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);
    }

    // -----------------------------------------------------------------------
    // _getTotalDebt wires to the dynamic manager (live pool read)
    // -----------------------------------------------------------------------

    function test_getTotalDebt_routesToDynamicManager_livePoolRead() public {
        assertEq(DYBRewardsShim(portfolioAccount).exposedGetTotalDebt(), 0, "starts zero");

        pool.setRaw(42e18);
        assertEq(
            DYBRewardsShim(portfolioAccount).exposedGetTotalDebt(),
            42e18,
            "live read from pool, no cache"
        );

        pool.setRaw(7e18);
        assertEq(
            DYBRewardsShim(portfolioAccount).exposedGetTotalDebt(),
            7e18,
            "decrement reflected on next read"
        );
    }

    // -----------------------------------------------------------------------
    // _decreaseTotalDebt wires to the dynamic manager
    // -----------------------------------------------------------------------

    function test_decreaseTotalDebt_routesToDynamicManager() public {
        // Seed pool debt 10e18, fund pa with 4e18 USDC -> pa pays 4, excess 0.
        pool.setRaw(10e18);
        underlying.mint(portfolioAccount, 4e18);

        // Snapshot collateral context (zero -- not strictly needed for the
        // wiring check) and call exposedDecreaseTotalDebt as an authorized
        // caller. _decreaseTotalDebt is internal but exposed via the shim;
        // the shim's exposed method has NO access-control gate by design,
        // so any caller can drive it -- we still prank for clarity.
        vm.prank(authorizedCaller);
        uint256 excess = DYBRewardsShim(portfolioAccount).exposedDecreaseTotalDebt(4e18);
        assertEq(excess, 0, "excess = 0 (amount == actualPaid)");
        assertEq(pool._rawDebt(), 6e18, "pool debt decremented");
    }

    function test_decreaseTotalDebt_excessReturnedWhenAmountExceedsDebt() public {
        // pool debt 3, caller offers 10 -> 7 excess.
        pool.setRaw(3e18);
        underlying.mint(portfolioAccount, 10e18);

        vm.prank(authorizedCaller);
        uint256 excess = DYBRewardsShim(portfolioAccount).exposedDecreaseTotalDebt(10e18);
        assertEq(excess, 7e18, "excess = 10 - 3");
        assertEq(pool._rawDebt(), 0, "pool debt cleared");
    }

    // -----------------------------------------------------------------------
    // _getLoanUtilization wires to the dynamic manager
    // -----------------------------------------------------------------------

    function test_getLoanUtilization_routesToDynamicManager() public {
        // No collateral -> no cap -> utilization is 0 when debt is 0,
        // type(uint256).max when debt > 0.
        pool.setRaw(0);
        assertEq(DYBRewardsShim(portfolioAccount).exposedGetLoanUtilization(), 0, "no debt -> 0");

        pool.setRaw(1);
        assertEq(
            DYBRewardsShim(portfolioAccount).exposedGetLoanUtilization(),
            type(uint256).max,
            "debt with no collateral -> max"
        );
    }

    // -----------------------------------------------------------------------
    // _isSwapAllowed blocks LP and gauge inputs
    // -----------------------------------------------------------------------

    function test_isSwapAllowed_blocksLpTokenAsInput() public view {
        assertFalse(
            DYBRewardsShim(portfolioAccount).exposedIsSwapAllowed(address(lp)),
            "LP token must be blocked as swap input"
        );
    }

    function test_isSwapAllowed_blocksGaugeAsInput() public view {
        assertFalse(
            DYBRewardsShim(portfolioAccount).exposedIsSwapAllowed(address(gauge)),
            "Gauge must be blocked as swap input"
        );
    }

    function test_isSwapAllowed_allowsArbitraryOtherToken() public view {
        assertTrue(
            DYBRewardsShim(portfolioAccount).exposedIsSwapAllowed(address(someOtherToken)),
            "Other tokens must be allowed"
        );
        assertTrue(
            DYBRewardsShim(portfolioAccount).exposedIsSwapAllowed(address(defaultToken)),
            "Default token allowed"
        );
        assertTrue(
            DYBRewardsShim(portfolioAccount).exposedIsSwapAllowed(address(underlying)),
            "Underlying allowed"
        );
    }

    // -----------------------------------------------------------------------
    // Constructor invariants
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroGauge() public {
        vm.expectRevert();
        new DYBRewardsShim(
            address(portfolioFactory),
            address(swapConfig),
            address(0), // zero gauge
            address(pool),
            address(defaultToken),
            address(underlying)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert();
        new DYBRewardsShim(
            address(portfolioFactory),
            address(swapConfig),
            address(gauge),
            address(pool),
            address(defaultToken),
            address(0) // zero underlying
        );
    }

    function test_constructor_storesImmutables() public view {
        assertEq(shim._gauge(), address(gauge), "_gauge stored");
        assertEq(shim._lpToken(), address(lp), "_lpToken derived from gauge.asset()");
        assertEq(shim._underlying(), address(underlying), "_underlying stored");
    }
}
