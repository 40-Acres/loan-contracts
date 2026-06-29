// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Facets under test
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";

// Infrastructure
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

// OpenZeppelin
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// LendingVault
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

/**
 * @title YieldBasisStakeCollateralNeutralityTest
 * @dev Failing-first tests for the security fix in YieldBasisLpFacet.setStakedMode().
 *
 *  BUG UNDER TEST
 *  --------------
 *  setStakedMode()'s stake branch deposits LP into the gauge with NO collateral
 *  reconciliation or enforcement:
 *
 *      if (staked) {
 *          uint256 lpBalance = _lpToken.balanceOf(address(this));
 *          require(lpBalance > 0, "Nothing to stake");
 *          _stake(lpBalance);          // <-- no snapshot, no enforce
 *      }
 *
 *  If the gauge mints fewer recoverable shares than LP sent (a lossy deposit),
 *  recoverable collateral drops while tracked `data.shares` / `data.debt` stay
 *  unchanged. A position exactly at the LTV limit becomes undercollateralized,
 *  but the stake tx does NOT revert. After the planned fix the stake records a
 *  shortfall baseline BEFORE _stake and enforces after, so the lossy stake at the
 *  limit reverts YieldBasisCollateralManager.UndercollateralizedDebt(shortfall).
 *
 *  The tunable gauge's setDepositFeeBps(N) makes deposit(assets) mint
 *  assets*(10000-N)/10000 shares while keeping all LP and leaving convertRatioBps
 *  at 1:1, so convertToAssets(sharesMinted) = sharesMinted < lpSent — recoverable
 *  collateral drops by N bps on stake.
 */
contract YieldBasisStakeCollateralNeutralityTest is Test {
    // Facets
    YieldBasisLpFacet public _ybBtcFacet;
    YieldBasisLpLendingFacet public _ybBtcLendingFacet;

    // Infrastructure
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;
    YieldBasisPortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;

    // Mock contracts
    MockYieldBasisLP public _ybBtc;                 // underlying LP token (8 decimals)
    MockERC20 public _usdc;                         // lending asset (8 decimals)
    MockERC20 public _ybToken;                      // YB reward token (18 decimals)
    MockTunableYieldBasisGauge public _gauge;       // tunable: lets us simulate a lossy stake
    LendingVault public _lendingVault;
    SwapConfig public _swapConfig;

    // Actors
    address public _user = address(0x40ac2e);
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    // Portfolio account (diamond proxy) for user
    address public _portfolioAccount;

    // Test amounts
    uint256 constant DEPOSIT_AMOUNT = 10e8;        // 10 ybBTC (8 decimals)
    uint256 constant VAULT_LIQUIDITY = 100_000e8;  // 100k USDC-equivalent in vault
    uint256 constant LTV_BPS = 7000;               // 70% LTV
    // 18-dec value-per-LP-share for an 8-dec collateral/underlying pair.
    uint256 constant PPS_DEC_SCALE = 1e28;

    function setUp() public {
        vm.startPrank(_owner);

        // --- Deploy portfolio manager and factory ---
        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-btc-stake-neutrality-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // --- Deploy config contracts (YB-specific so getStakedMode() works) ---
        YbConfigDeployer configDeployer = new YbConfigDeployer();
        (_portfolioFactoryConfig, , _loanConfig, ) = configDeployer.deployYb(address(_portfolioFactory), _owner);

        // --- Deploy mock tokens ---
        _ybBtc = new MockYieldBasisLP("ybBTC", "ybBTC", 8);
        _ybBtc.setPricePerShare(PPS_DEC_SCALE);
        _usdc = new MockERC20("USDC", "USDC", 8);
        _ybToken = new MockERC20("YieldBasis", "YB", 18);

        // --- Deploy TUNABLE mock gauge (so we can simulate a lossy stake) ---
        _gauge = new MockTunableYieldBasisGauge(address(_ybBtc));

        // --- Deploy SwapConfig (constructor parity with the reference test) ---
        SwapConfig swapConfigImpl = new SwapConfig();
        _swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (_owner))
            ))
        );

        // --- Deploy LendingVault behind ERC1967Proxy. originationFeeBps = 0 so
        //     borrow math is clean: maxLoan = collateralValue * LTV / 10000. ---
        LendingVault lendingVaultImpl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(_usdc),              // asset
            address(_portfolioFactory),  // portfolioFactory
            _owner,                      // owner
            "Lending Vault",             // name
            "lVAULT",                    // symbol
            0                            // originationFeeBps (clean borrow math)
        );
        ERC1967Proxy lendingVaultProxy = new ERC1967Proxy(address(lendingVaultImpl), initData);
        _lendingVault = LendingVault(address(lendingVaultProxy));

        // Fund lending vault with USDC liquidity
        _usdc.mint(address(_lendingVault), VAULT_LIQUIDITY);

        // --- Configure (LTV-based like-to-like YB LP market) ---
        _loanConfig.setMultiplier(LTV_BPS);
        _loanConfig.setLtv(LTV_BPS);
        _portfolioFactoryConfig.setLoanContract(address(_lendingVault));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        // --- Deploy and register YieldBasisLpFacet ---
        _ybBtcFacet = new YieldBasisLpFacet(address(_portfolioFactory), address(_gauge), address(_ybToken), address(_lendingVault));
        {
            bytes4[] memory selectors = new bytes4[](9);
            selectors[0] = YieldBasisLpFacet.deposit.selector;
            selectors[1] = YieldBasisLpFacet.withdraw.selector;
            selectors[2] = YieldBasisLpFacet.setStakedMode.selector;
            selectors[3] = YieldBasisLpFacet.getStakingState.selector;
            selectors[4] = YieldBasisLpFacet.getStakedMode.selector;
            selectors[5] = ICollateralFacet.enforceCollateralRequirements.selector;
            selectors[6] = ICollateralFacet.getTotalLockedCollateral.selector;
            selectors[7] = ICollateralFacet.getTotalDebt.selector;
            selectors[8] = ICollateralFacet.getMaxLoan.selector;
            _facetRegistry.registerFacet(address(_ybBtcFacet), selectors, "YieldBasisLpFacet");
        }

        // --- Deploy and register YieldBasisLpLendingFacet (creates debt) ---
        _ybBtcLendingFacet = new YieldBasisLpLendingFacet(
            address(_portfolioFactory),
            address(_lendingVault),
            address(_gauge)
        );
        {
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = YieldBasisLpLendingFacet.borrow.selector;
            selectors[1] = YieldBasisLpLendingFacet.pay.selector;
            _facetRegistry.registerFacet(address(_ybBtcLendingFacet), selectors, "YieldBasisLpLendingFacet");
        }

        // --- Set authorized caller ---
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        // --- Create portfolio account for user ---
        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // --- Fund user with ybBTC ---
        _ybBtc.mint(_user, DEPOSIT_AMOUNT * 10);
    }

    // ============ Helpers ============

    function _multicall(bytes[] memory calldatas) internal {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(_portfolioFactory);
        }
        _portfolioManager.multicall(calldatas, factories);
    }

    function _singleMulticall(bytes memory data) internal {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        _multicall(calldatas);
    }

    /// @dev Deposit LP tokens into the portfolio account (held unstaked).
    function _depositLP(uint256 amount) internal {
        vm.startPrank(_user);
        _ybBtc.approve(_portfolioAccount, amount);
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount));
        vm.stopPrank();
    }

    /// @dev Borrow USDC against collateral (via multicall; requires onlyPortfolioManagerMulticall).
    function _borrow(uint256 amount) internal {
        vm.startPrank(_user);
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, amount));
        vm.stopPrank();
    }

    /// @dev Repay all outstanding debt.
    function _repayAll() internal {
        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        if (debt == 0) return;
        _usdc.mint(_user, debt);
        vm.startPrank(_user);
        _usdc.approve(_portfolioAccount, debt);
        YieldBasisLpLendingFacet(_portfolioAccount).pay(debt);
        vm.stopPrank();
    }

    /// @dev Set the protocol-wide directive then sweep this account into it.
    function _syncAndSetStake(bool mode) internal {
        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(mode);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 1: THE failing-first / bug-reproducing test
    // ============================================================

    /**
     * @notice At the LTV limit, a lossy stake silently drops recoverable collateral
     *         below what the debt requires. On the CURRENT (unfixed) code this does
     *         NOT revert -> this test FAILS with "call did not revert as expected".
     *         After the fix it reverts UndercollateralizedDebt(shortfall).
     */
    function test_setStakedMode_lossyStake_atLtvLimit_reverts() public {
        // Deposit 10e8, held unstaked.
        _depositLP(DEPOSIT_AMOUNT);

        // Borrow exactly max: position sits precisely at the LTV limit.
        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);

        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan (exactly at the limit)");
        assertGt(debt, 0, "Sanity: there must be debt for a shortfall to exist");

        // Make the gauge lossy: deposit mints 99% of LP as recoverable shares.
        vm.prank(_owner);
        _gauge.setDepositFeeBps(100); // 1% loss

        // Recoverable LP after stake = 10e8 * 0.99 = 9.9e8.
        //   borrowable collateral = min(depositedAssetValue=10e18, current=9.9e18) = 9.9e18
        //   maxLoanIgnoreSupply (8-dec native, 70% LTV) = 9.9e8 * 7000 / 10000 = 6.93e8
        //   shortfall = debt(7e8) - 6.93e8 = 7e6
        uint256 recoverableLp = (DEPOSIT_AMOUNT * 9900) / 10000;      // 9.9e8
        uint256 borrowable18 = (recoverableLp * PPS_DEC_SCALE) / 1e18; // 9.9e18
        uint256 valueNative = borrowable18 / (10 ** (18 - 8));         // 9.9e8
        uint256 maxLoanAfter = (valueNative * LTV_BPS) / 10000;        // 6.93e8
        uint256 expectedShortfall = debt - maxLoanAfter;              // 7e6

        // Inline the two pranks of _syncAndSetStake so vm.expectRevert sits
        // immediately before the setStakedMode() call.
        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(true);

        // CURRENT CODE: setStakedMode does not enforce, so NO revert happens here
        // and this expectation FAILS. That failure IS the reproduced bug.
        vm.expectRevert(
            abi.encodeWithSelector(YieldBasisCollateralManager.UndercollateralizedDebt.selector, expectedShortfall)
        );
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 2: lossy stake with borrow buffer -> succeeds & ratchets
    // ============================================================

    /**
     * @notice A lossy stake well below the LTV limit succeeds: the ~1% collateral
     *         loss is absorbed by the borrow buffer, so no new shortfall appears.
     *         Tracked collateral ratchets down ~1% and the LP is now staked.
     */
    function test_setStakedMode_lossyStake_withBuffer_succeedsAndRatchets() public {
        _depositLP(DEPOSIT_AMOUNT);

        // Borrow well below max (max is 7e8; borrow 3e8).
        _borrow(3e8);

        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        vm.prank(_owner);
        _gauge.setDepositFeeBps(100); // 1% loss

        // Succeeds: shortfall stays 0 because debt (3e8) <= post-stake maxLoan (6.93e8).
        _syncAndSetStake(true);

        // LP is now staked in the gauge.
        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertGt(staked, 0, "LP should be staked after stake");

        // Tracked collateral ratcheted down ~1% (clamped to recoverable LP).
        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 expectedAfter = (collateralBefore * 9900) / 10000;
        assertLt(collateralAfter, collateralBefore, "Collateral should ratchet down after lossy stake");
        assertApproxEqAbs(collateralAfter, expectedAfter, 1e10, "Collateral should reflect ~1% loss");
    }

    // ============================================================
    // Test 3: lossy stake with zero debt -> succeeds
    // ============================================================

    /**
     * @notice With no debt the shortfall is always 0, so a lossy stake succeeds.
     *         Tracked collateral still ratchets down ~1% and the LP is staked.
     */
    function test_setStakedMode_lossyStake_zeroDebt_succeeds() public {
        _depositLP(DEPOSIT_AMOUNT);

        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Precondition: no debt");

        vm.prank(_owner);
        _gauge.setDepositFeeBps(100); // 1% loss

        _syncAndSetStake(true);

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertGt(staked, 0, "LP should be staked after stake");

        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 expectedAfter = (collateralBefore * 9900) / 10000;
        assertLt(collateralAfter, collateralBefore, "Collateral should ratchet down after lossy stake");
        assertApproxEqAbs(collateralAfter, expectedAfter, 1e10, "Collateral should reflect ~1% loss");
    }

    // ============================================================
    // Test 4: lossless stake at the LTV limit -> succeeds (guards over-strictness)
    // ============================================================

    /**
     * @notice An honest 1:1 gauge at the LTV limit must NOT revert after the fix.
     *         Recoverable collateral is unchanged by the stake, so there is no new
     *         shortfall. Guards against the fix being over-strict on honest gauges.
     */
    function test_setStakedMode_losslessStake_atLtvLimit_succeeds() public {
        _depositLP(DEPOSIT_AMOUNT);

        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan (exactly at the limit)");

        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // depositFeeBps stays 0 (default) -> 1:1, lossless stake.
        _syncAndSetStake(true);

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertGt(staked, 0, "LP should be staked after stake");

        // Neutral: tracked collateral unchanged by an honest stake.
        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "Lossless stake must not change tracked collateral");

        // Debt unchanged.
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), debt, "Debt must be unchanged by stake");
    }

    // ============================================================
    // Test 5: unstake while underwater -> stays lenient (regression guard)
    // ============================================================

    /**
     * @notice De-risking (unstake) must never revert, even underwater. This passes
     *         on CURRENT code and must keep passing after the fix: the fix only
     *         hardens the stake branch, leaving the unstake branch lenient.
     */
    function test_setStakedMode_unstake_underwater_staysLenient() public {
        _depositLP(DEPOSIT_AMOUNT);

        // Stake (lossless) so there are gauge shares to unstake.
        _syncAndSetStake(true);
        (uint256 stakedAfterStake, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertGt(stakedAfterStake, 0, "Precondition: LP staked");

        // Borrow max while staked.
        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        assertGt(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Precondition: debt exists");

        // Drop pps to push the position underwater (0.8x).
        _ybBtc.setPricePerShare(8 * (PPS_DEC_SCALE / 10));

        // Unstake must SUCCEED despite being underwater (de-risking is lenient).
        _syncAndSetStake(false);

        (uint256 stakedAfterUnstake, uint256 unstakedAfterUnstake) =
            YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfterUnstake, 0, "Should have 0 staked after unstake");
        assertGt(unstakedAfterUnstake, 0, "LP should be back on the account after unstake");
    }
}
