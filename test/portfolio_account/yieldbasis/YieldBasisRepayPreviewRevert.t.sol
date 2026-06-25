// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * YieldBasisCollateralManager -- repay must never revert on a paused source
 * ==========================================================================
 *
 * The YB repay path (decreaseTotalDebt -> _snapshotIfNeededRepay) wraps BOTH
 * revert-prone collateral reads in try/catch:
 *   (a) the gauge ratchet read   : _actualLpRepaySafe -> gauge.convertToAssets
 *   (b) the YB market price read : _resolveCollateralValueRepaySafe ->
 *                                  lp.pricePerShare + lp.preview_withdraw
 * If either reverts (paused / emergency mode) the shortfall snapshot is
 * skipped and the repay proceeds -- the payment flows through the lending
 * pool, never the collateral source.
 *
 * The borrow path is UNCHANGED: increaseTotalDebt -> _snapshotIfNeeded uses
 * the strict reads, so a paused YB market or gauge still blocks a borrow.
 *
 * This file proves the asymmetry for the regular (LoanV2-style) YB manager:
 *   - paused YB market  : repay SUCCEEDS, borrow REVERTS
 *   - paused gauge      : repay SUCCEEDS, borrow REVERTS
 * across both the unstaked (direct LP) and staked (gauge) collateral modes.
 * ==========================================================================
 */

import {Test} from "forge-std/Test.sol";

import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPausableYieldBasisLP} from "../../mocks/MockPausableYieldBasisLP.sol";
import {MockPausableYieldBasisGauge} from "../../mocks/MockPausableYieldBasisGauge.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract YieldBasisRepayPreviewRevertTest is Test {
    YieldBasisLpFacet public _ybFacet;
    YieldBasisLpLendingFacet public _lendingFacet;

    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    YieldBasisPortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;

    MockPausableYieldBasisLP public _ybLp;
    MockPausableYieldBasisGauge public _gauge;
    MockERC20 public _underlying;
    LendingVault public _lendingVault;

    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address public _user = address(0x40ac2e);
    address public _authorizedCaller = address(0xaaaaa);

    address public _portfolioAccount;

    uint256 internal constant DEPOSIT_AMOUNT = 10e18;
    uint256 internal constant PPS = 1e18;
    uint256 internal constant VAULT_LIQUIDITY = 1_000e18;
    uint256 internal constant LTV_BPS = 7000; // 70% like-to-like
    uint256 internal constant BORROW_AMOUNT = 5e18; // < 70% of 10e18

    function setUp() public {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory factory, FacetRegistry registry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-repay-preview-revert-test")))
        );
        _portfolioFactory = factory;
        _facetRegistry = registry;

        YbConfigDeployer configDeployer = new YbConfigDeployer();
        (_portfolioFactoryConfig, , _loanConfig, ) = configDeployer.deployYb(address(_portfolioFactory), _owner);

        _underlying = new MockERC20("WETH", "WETH", 18);
        _ybLp = new MockPausableYieldBasisLP("ybETH", "ybETH", 18, address(_underlying));
        _ybLp.setPricePerShare(PPS);
        _gauge = new MockPausableYieldBasisGauge(address(_ybLp));

        // Seed the LP mock with underlying so gauge withdraws can deliver.
        _underlying.mint(address(_ybLp), 1_000e18);

        LendingVault lendingVaultImpl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(_underlying),
            address(_portfolioFactory),
            _owner,
            "Lending Vault",
            "lVAULT",
            uint256(0)
        );
        ERC1967Proxy lendingVaultProxy = new ERC1967Proxy(address(lendingVaultImpl), initData);
        _lendingVault = LendingVault(address(lendingVaultProxy));
        _underlying.mint(address(_lendingVault), VAULT_LIQUIDITY);

        _loanConfig.setMultiplier(LTV_BPS);
        _loanConfig.setLtv(LTV_BPS);
        _portfolioFactoryConfig.setLoanContract(address(_lendingVault));
        // Default to unstaked mode; staked-mode tests flip it explicitly.
        _portfolioFactoryConfig.setStakedGaugeMode(false);
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        _ybFacet = new YieldBasisLpFacet(
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
            _facetRegistry.registerFacet(address(_ybFacet), selectors, "YieldBasisLpFacet");
        }

        _lendingFacet = new YieldBasisLpLendingFacet(
            address(_portfolioFactory),
            address(_lendingVault),
            address(_gauge)
        );
        {
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = YieldBasisLpLendingFacet.borrow.selector;
            selectors[1] = YieldBasisLpLendingFacet.pay.selector;
            _facetRegistry.registerFacet(address(_lendingFacet), selectors, "YieldBasisLpLendingFacet");
        }

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);
        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);
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

    function _borrow(uint256 amount) internal {
        vm.prank(_user);
        _multicall(abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, amount));
    }

    function _pay(uint256 amount) internal {
        vm.startPrank(_user);
        _underlying.approve(_portfolioAccount, amount);
        YieldBasisLpLendingFacet(_portfolioAccount).pay(amount);
        vm.stopPrank();
    }

    /// @dev Borrow proceeds go to the owner; ensure the owner can fund a repay.
    function _fundUser(uint256 amount) internal {
        _underlying.mint(_user, amount);
    }

    function _setStaked(bool mode) internal {
        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(mode);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    function _debt() internal view returns (uint256) {
        return ICollateralFacet(_portfolioAccount).getTotalDebt();
    }

    // ========================================================================
    // (a) Paused YB MARKET (pricePerShare / preview_withdraw revert)
    //     Unstaked mode: LP held directly, no gauge read involved.
    // ========================================================================

    /// @notice Repay must succeed when the YB market is paused (pricePerShare reverts).
    function test_repay_succeeds_whenYbMarketPaused_unstaked() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        uint256 debtBefore = _debt();
        assertEq(debtBefore, BORROW_AMOUNT, "debt is the borrow before repay");

        // Pause the YB market: pricePerShare + preview_withdraw revert.
        _ybLp.setPaused(true);
        vm.expectRevert(bytes("paused"));
        _ybLp.pricePerShare();

        uint256 amountPaid = 2e18;
        _fundUser(amountPaid);
        _pay(amountPaid);

        uint256 debtAfter = _debt();
        assertLt(debtAfter, debtBefore, "repay must reduce debt even when YB market read reverts");
        assertEq(debtAfter, debtBefore - amountPaid, "debt drops by exactly the repaid amount");
        assertEq(
            ILendingPool(address(_lendingVault)).getDebtBalance(_portfolioAccount),
            debtBefore - amountPaid,
            "pool debt drops by exactly the repaid amount"
        );
    }

    /// @notice Borrow must REVERT when the YB market is paused -- borrow-side gate intact.
    function test_borrow_reverts_whenYbMarketPaused_unstaked() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        _ybLp.setPaused(true);

        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory cds = new bytes[](1);
        cds[0] = abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, 1e18);
        vm.expectRevert(bytes("paused"));
        _portfolioManager.multicall(cds, facs);
        vm.stopPrank();

        assertEq(_debt(), BORROW_AMOUNT, "borrow must not land when YB market is paused");
    }

    // ========================================================================
    // (b) Paused GAUGE (convertToAssets reverts)
    //     Staked mode: LP staked into the gauge so _actualLp reads the gauge.
    // ========================================================================

    /// @notice Repay must succeed when the gauge is paused (convertToAssets reverts).
    function test_repay_succeeds_whenGaugePaused_staked() public {
        _deposit(DEPOSIT_AMOUNT);
        // Stake into the gauge so the ratchet read (_actualLp) hits the gauge.
        _setStaked(true);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT, "LP staked into gauge");
        assertEq(unstaked, 0, "no direct LP");

        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        uint256 debtBefore = _debt();
        assertEq(debtBefore, BORROW_AMOUNT, "debt is the borrow before repay");

        // Pause the gauge convert read used by the repay-path ratchet.
        _gauge.setConvertPaused(true);
        vm.expectRevert(bytes("paused"));
        _gauge.convertToAssets(1);

        uint256 amountPaid = 2e18;
        _fundUser(amountPaid);
        _pay(amountPaid);

        uint256 debtAfter = _debt();
        assertLt(debtAfter, debtBefore, "repay must reduce debt even when gauge read reverts");
        assertEq(debtAfter, debtBefore - amountPaid, "debt drops by exactly the repaid amount");
        assertEq(
            ILendingPool(address(_lendingVault)).getDebtBalance(_portfolioAccount),
            debtBefore - amountPaid,
            "pool debt drops by exactly the repaid amount"
        );
    }

    /// @notice Borrow must REVERT when the gauge is paused -- borrow-side gate intact.
    function test_borrow_reverts_whenGaugePaused_staked() public {
        _deposit(DEPOSIT_AMOUNT);
        _setStaked(true);

        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        _gauge.setConvertPaused(true);

        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory cds = new bytes[](1);
        cds[0] = abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, 1e18);
        vm.expectRevert(bytes("paused"));
        _portfolioManager.multicall(cds, facs);
        vm.stopPrank();

        assertEq(_debt(), BORROW_AMOUNT, "borrow must not land when gauge is paused");
    }
}
