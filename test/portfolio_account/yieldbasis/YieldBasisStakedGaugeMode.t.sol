// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasis stakedGaugeMode + setStakedMode coverage
 * ===========================================================================
 *
 * The YieldBasis LP refactor moved the auto-stake decision from a per-account
 * heuristic ("is the gauge balance > 0?") to a factory-wide directive on
 * YieldBasisPortfolioFactoryConfig.stakedGaugeMode. The unified
 * setStakedMode(bool) replaces the prior stake()/unstake() pair.
 *
 * This file pins the new contract:
 *   - getStakedGaugeMode() / setStakedGaugeMode() on the YB factory config:
 *     * onlyOwner setter, persists, emits StakedGaugeModeUpdated(old, new)
 *   - getStakedMode() on the facet returns the factory flag verbatim
 *   - deposit() branches on the factory flag, NOT gauge balance
 *   - setStakedMode()/(false) preconditions and access control
 *   - withdraw() resilience: pulls from direct LP first, redeems shortfall
 *     from the gauge, tolerates dust gauge balances and mixed states
 *
 * Setup mirrors the rest of the YB suite: PortfolioManager + PortfolioFactory
 * + YieldBasisPortfolioFactoryConfig + LendingVault + mock LP/gauge.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";

import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockYieldBasisGauge} from "../../mocks/MockYieldBasisGauge.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract YieldBasisStakedGaugeModeTest is Test {
    YieldBasisLpFacet public _facet;
    YieldBasisLpClaimingFacet public _claimingFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;
    YieldBasisPortfolioFactoryConfig public _config;
    LoanConfig public _loanConfig;

    MockYieldBasisLP public _lp;
    MockERC20 public _ybToken;
    MockERC20 public _usdc;
    MockYieldBasisGauge public _gauge;
    LendingVault public _vault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address public _stranger = address(0xbeef);

    uint256 constant DEPOSIT_AMOUNT = 1e18;
    uint256 constant VAULT_LIQUIDITY = 100_000e18;

    // Re-declared locally because Solidity disallows referencing events from
    // contracts we don't inherit when using vm.expectEmit's struct-style match.
    event StakedGaugeModeUpdated(bool oldValue, bool newValue);

    function setUp() public {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory pf, FacetRegistry fr) = _portfolioManager.deployFactory(
            keccak256("yb-staked-gauge-mode")
        );
        _portfolioFactory = pf;
        _facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (_config, , _loanConfig, ) = deployer.deployYb(address(_portfolioFactory), _owner);

        _lp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        _ybToken = new MockERC20("YB", "YB", 18);
        _usdc = new MockERC20("USDC", "USDC", 18);
        _gauge = new MockYieldBasisGauge(address(_lp));

        LendingVault vaultImpl = new LendingVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(_usdc), address(_portfolioFactory), _owner, "lvault", "lv", 0)
            )
        );
        _vault = LendingVault(address(vaultProxy));
        _usdc.mint(address(_vault), VAULT_LIQUIDITY);

        _loanConfig.setMultiplier(7000);
        _config.setLoanContract(address(_vault));
        _portfolioFactory.setPortfolioFactoryConfig(address(_config));

        _facet = new YieldBasisLpFacet(address(_portfolioFactory), address(_gauge), address(_ybToken), address(_vault));
        bytes4[] memory facetSelectors = new bytes4[](9);
        facetSelectors[0] = YieldBasisLpFacet.deposit.selector;
        facetSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        facetSelectors[2] = YieldBasisLpFacet.setStakedMode.selector;
        facetSelectors[3] = YieldBasisLpFacet.getStakingState.selector;
        facetSelectors[4] = YieldBasisLpFacet.getStakedMode.selector;
        facetSelectors[5] = ICollateralFacet.enforceCollateralRequirements.selector;
        facetSelectors[6] = ICollateralFacet.getTotalLockedCollateral.selector;
        facetSelectors[7] = ICollateralFacet.getTotalDebt.selector;
        facetSelectors[8] = ICollateralFacet.getMaxLoan.selector;
        _facetRegistry.registerFacet(address(_facet), facetSelectors, "YieldBasisLpFacet");

        _claimingFacet = new YieldBasisLpClaimingFacet(address(_portfolioFactory), address(_gauge), address(_vault));
        bytes4[] memory cl = new bytes4[](2);
        cl[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        cl[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        _facetRegistry.registerFacet(address(_claimingFacet), cl, "YieldBasisLpClaimingFacet");

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);
        _lp.mint(_user, DEPOSIT_AMOUNT * 100);
    }

    // ============ Helpers ============

    function _depositViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        _lp.approve(_portfolioAccount, amount);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        _portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _withdrawViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, amount);
        _portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    /// @dev Set the protocol-wide directive then sweep this account into it.
    ///      `setStakedMode` reads `getStakedGaugeMode()`; this helper keeps
    ///      tests terse while making the directive flip explicit.
    function _syncAndSetStake(bool mode) internal {
        vm.prank(_owner);
        _config.setStakedGaugeMode(mode);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    // ============ Config: setStakedGaugeMode ============

    /// @notice Default value of stakedGaugeMode is false (zero-init).
    function test_factoryFlag_defaultIsFalse() public view {
        assertEq(_config.getStakedGaugeMode(), false, "default is false");
    }

    /// @notice Owner can flip stakedGaugeMode to true; reads see new value.
    function test_factoryFlag_setTrue_persists() public {
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);
        assertTrue(_config.getStakedGaugeMode(), "flag persists across reads");
    }

    /// @notice Owner can flip back from true to false.
    function test_factoryFlag_setFalseAfterTrue_persists() public {
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);
        vm.prank(_owner);
        _config.setStakedGaugeMode(false);
        assertEq(_config.getStakedGaugeMode(), false, "flag flipped back to false");
    }

    /// @notice setStakedGaugeMode emits StakedGaugeModeUpdated(oldValue, newValue).
    ///         Initial set: (false, true). Subsequent set: (true, false).
    function test_factoryFlag_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(_config));
        emit StakedGaugeModeUpdated(false, true);
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);

        vm.expectEmit(false, false, false, true, address(_config));
        emit StakedGaugeModeUpdated(true, false);
        vm.prank(_owner);
        _config.setStakedGaugeMode(false);
    }

    /// @notice Even setting the same value emits the event (with oldValue == newValue).
    ///         This is intentional — the contract does not short-circuit no-ops.
    function test_factoryFlag_emitsEvenForUnchangedValue() public {
        vm.expectEmit(false, false, false, true, address(_config));
        emit StakedGaugeModeUpdated(false, false);
        vm.prank(_owner);
        _config.setStakedGaugeMode(false);
    }

    /// @notice Non-owner cannot setStakedGaugeMode — reverts with OZ Ownable error.
    function test_factoryFlag_revertsForNonOwner() public {
        vm.prank(_stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _stranger));
        _config.setStakedGaugeMode(true);
    }

    /// @notice Authorized caller is NOT owner — also blocked from flipping the factory flag.
    function test_factoryFlag_revertsForAuthorizedCaller() public {
        vm.prank(_authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _authorizedCaller));
        _config.setStakedGaugeMode(true);
    }

    // ============ Facet getStakedMode reads factory flag ============

    /// @notice Facet getStakedMode() returns the factory flag verbatim.
    function test_facetGetStakedMode_mirrorsFactoryFlag() public {
        // Default false
        assertEq(YieldBasisLpFacet(_portfolioAccount).getStakedMode(), false, "default false");

        // Flip to true
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);
        assertEq(YieldBasisLpFacet(_portfolioAccount).getStakedMode(), true, "facet sees true");

        // Flip back to false
        vm.prank(_owner);
        _config.setStakedGaugeMode(false);
        assertEq(YieldBasisLpFacet(_portfolioAccount).getStakedMode(), false, "facet sees false");
    }

    /// @notice The facet does NOT use gauge balance to derive the mode anymore.
    ///         Even with non-zero gauge balance, getStakedMode() returns the flag.
    function test_facetGetStakedMode_ignoresGaugeBalance() public {
        // Deposit + stake (via _syncAndSetStake which sets the directive too).
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _syncAndSetStake(true);
        assertEq(_gauge.balanceOf(_portfolioAccount), DEPOSIT_AMOUNT, "precondition: gauge has shares");

        // Now flip the directive back to false and confirm the facet reports
        // the directive — NOT the lingering gauge balance.
        vm.prank(_owner);
        _config.setStakedGaugeMode(false);
        assertEq(YieldBasisLpFacet(_portfolioAccount).getStakedMode(), false, "facet reads directive, ignores gauge balance");
    }

    // ============ deposit() branches on the factory flag ============

    /// @notice With flag=false (default), deposit holds LP unstaked on the account.
    function test_deposit_withFlagFalse_doesNotAutoStake() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "no auto-stake when flag is false");
        assertEq(unstaked, DEPOSIT_AMOUNT, "deposit sits as LP on the account");
    }

    /// @notice With flag=true, deposit auto-stakes the freshly deposited LP into the gauge.
    function test_deposit_withFlagTrue_autoStakes() public {
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);

        _depositViaMulticall(DEPOSIT_AMOUNT);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT, "auto-stake fired: full deposit in gauge");
        assertEq(unstaked, 0, "no LP left on the account");
        assertEq(_lp.balanceOf(_portfolioAccount), 0, "account holds no LP");
    }

    /// @notice Flag is read at deposit-time, not pinned per-account: flipping the
    ///         flag between deposits switches behavior without redeployment.
    function test_deposit_flagFlipChangesBehavior() public {
        // First deposit — flag false → unstaked
        _depositViaMulticall(DEPOSIT_AMOUNT);
        (uint256 stakedA, uint256 unstakedA) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedA, 0, "first deposit unstaked under false flag");
        assertEq(unstakedA, DEPOSIT_AMOUNT, "first deposit on account");

        // Flip flag, then second deposit — auto-stake
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);

        _depositViaMulticall(DEPOSIT_AMOUNT);
        (uint256 stakedB, uint256 unstakedB) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        // The first deposit's LP is still on the account (unstaked); second deposit
        // gets auto-staked. So gauge holds DEPOSIT_AMOUNT (just the second deposit),
        // and the account still holds DEPOSIT_AMOUNT from the first.
        assertEq(stakedB, DEPOSIT_AMOUNT, "second deposit auto-staked");
        assertEq(unstakedB, DEPOSIT_AMOUNT, "first deposit untouched");
    }

    // ============ setStakedMode preconditions ============

    /// @notice setStakedMode() reverts with "Nothing to stake" when the account
    ///         has zero unstaked LP. Guards against emitting a misleading 0-share
    ///         Staked event.
    function test_setStakedMode_true_revertsOnZeroLp() public {
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);
        vm.prank(_authorizedCaller);
        vm.expectRevert("Nothing to stake");
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    /// @notice setStakedMode() succeeds when there's unstaked LP — moves all of
    ///         it into the gauge. All-or-nothing: the function does not take an amount.
    function test_setStakedMode_true_stakesEntireLpBalance() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        // Sanity: all LP is unstaked (deposited with directive=false default).
        assertEq(_lp.balanceOf(_portfolioAccount), DEPOSIT_AMOUNT, "precondition: LP on account");

        // Flip directive then sweep — setStakedMode reads the directive.
        _syncAndSetStake(true);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT, "full balance now in gauge");
        assertEq(unstaked, 0, "no LP left on account");
    }

    /// @notice setStakedMode() reverts with "Nothing staked" when the account
    ///         has zero gauge shares.
    function test_setStakedMode_false_revertsOnZeroGauge() public {
        // No deposit, so nothing in the gauge.
        vm.prank(_authorizedCaller);
        vm.expectRevert("Nothing staked");
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    /// @notice setStakedMode() succeeds when there's a gauge balance — redeems
    ///         all gauge shares, reconciles tracked shares, and emits Unstaked.
    function test_setStakedMode_false_redeemsEntireGaugeBalance() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        // First sweep: directive=true → stake LP into gauge.
        _syncAndSetStake(true);
        assertEq(_gauge.balanceOf(_portfolioAccount), DEPOSIT_AMOUNT, "precondition: gauge has shares");

        // Second sweep: directive=false → redeem all gauge shares.
        _syncAndSetStake(false);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "gauge fully redeemed");
        assertEq(unstaked, DEPOSIT_AMOUNT, "all LP returned to account");
    }

    /// @notice setStakedMode READS the factory flag but does NOT WRITE it.
    ///         The function is a per-account sweep that aligns to the
    ///         protocol-wide directive — it must not silently flip the flag.
    function test_setStakedMode_doesNotWriteFactoryFlag() public {
        // Flip factory flag to true and deposit (auto-stakes via deposit hook).
        vm.prank(_owner);
        _config.setStakedGaugeMode(true);
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Flip directive to false and sweep — setStakedMode unstakes.
        vm.prank(_owner);
        _config.setStakedGaugeMode(false);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();

        // The factory flag stays at whatever the OWNER last set — the sweep
        // didn't write it back to true.
        assertFalse(_config.getStakedGaugeMode(), "factory flag still false after sweep");
        assertFalse(YieldBasisLpFacet(_portfolioAccount).getStakedMode(), "facet reads the post-set value");
    }

    // ============ setStakedMode access control ============

    /// @notice setStakedMode is onlyAuthorizedCaller. Random EOAs can't call it.
    function test_setStakedMode_revertsForRandomCaller() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(_stranger);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();

        vm.prank(_stranger);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    /// @notice The portfolio owner (user) is NOT an authorized caller — also blocked.
    function test_setStakedMode_revertsForPortfolioOwner() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(_user);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    /// @notice Even the deployer/owner of PortfolioManager is NOT an authorized caller —
    ///         only addresses set via setAuthorizedCaller can sweep.
    function test_setStakedMode_revertsForManagerOwner() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(_owner);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    // ============ withdraw() resilience: dust + mixed states ============

    /// @notice Dust gauge balance + sufficient direct LP: withdraw pulls from direct
    ///         LP and never touches the gauge. Tolerates the dust without reverting.
    function test_withdraw_dustGauge_usesDirectLpAndIgnoresGauge() public {
        // Deposit holds LP on account. Then donate a wei of gauge shares to simulate
        // dust drift — gauge balance > 0 but data.shares == DEPOSIT_AMOUNT (not staked).
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Manually mint 1 wei of gauge shares to the account (dust). The mock gauge
        // is a plain ERC4626; calling deposit from a stranger to fund the account.
        // We use the gauge's underlying transfer + a direct deposit from a helper.
        address dustHelper = address(0xd057);
        _lp.mint(dustHelper, 1);
        vm.startPrank(dustHelper);
        _lp.approve(address(_gauge), 1);
        _gauge.deposit(1, _portfolioAccount);
        vm.stopPrank();

        assertEq(_gauge.balanceOf(_portfolioAccount), 1, "precondition: 1 wei dust in gauge");
        assertEq(_lp.balanceOf(_portfolioAccount), DEPOSIT_AMOUNT, "precondition: full LP on account");

        // Withdraw the entire tracked amount — direct LP covers it, gauge untouched.
        uint256 userBefore = _lp.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        uint256 userAfter = _lp.balanceOf(_user);

        assertEq(userAfter - userBefore, DEPOSIT_AMOUNT, "user receives full deposit from direct LP");
        assertEq(_gauge.balanceOf(_portfolioAccount), 1, "dust gauge balance untouched");
        assertEq(_lp.balanceOf(_portfolioAccount), 0, "all direct LP swept to user");
    }

    /// @notice Mixed state — half on account, half in gauge. Withdraw pulls from
    ///         direct LP first, redeems shortfall from the gauge.
    function test_withdraw_mixedState_usesDirectFirstThenGauge() public {
        // Deposit, then stake half by depositing+staking a smaller amount on top.
        // To get into "mixed" state cleanly: deposit twice the amount, stake first,
        // then deposit again with flag false → first half in gauge, second half on account.
        _depositViaMulticall(DEPOSIT_AMOUNT); // unstaked
        _syncAndSetStake(true); // half (first deposit) in gauge — directive flipped to true
        // Reset directive so the next deposit doesn't auto-stake.
        vm.prank(_owner);
        _config.setStakedGaugeMode(false);

        // Second deposit lands on account (flag false).
        _depositViaMulticall(DEPOSIT_AMOUNT);

        (uint256 stakedBefore, uint256 unstakedBefore) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedBefore, DEPOSIT_AMOUNT, "precondition: first deposit in gauge");
        assertEq(unstakedBefore, DEPOSIT_AMOUNT, "precondition: second deposit on account");

        // Withdraw 1.5x DEPOSIT — direct LP (DEPOSIT) covers half, shortfall (0.5 DEPOSIT)
        // comes from gauge. Final: gauge holds 0.5 DEPOSIT, account holds 0.
        uint256 toWithdraw = (DEPOSIT_AMOUNT * 3) / 2;
        uint256 userBefore = _lp.balanceOf(_user);
        _withdrawViaMulticall(toWithdraw);
        uint256 userAfter = _lp.balanceOf(_user);

        assertEq(userAfter - userBefore, toWithdraw, "user received exact withdraw amount");

        (uint256 stakedAfter, uint256 unstakedAfter) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfter, DEPOSIT_AMOUNT / 2, "gauge has the remaining half");
        assertEq(unstakedAfter, 0, "account drained of LP");

        // Tracked collateral matches the leftover.
        assertEq(
            ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(),
            DEPOSIT_AMOUNT / 2,
            "tracked collateral reflects the 0.5 DEPOSIT remaining in gauge"
        );
    }

    /// @notice Sanity: with flag false and nothing in gauge, withdraw still pulls
    ///         from direct LP without ever calling the gauge.
    function test_withdraw_noGaugeShares_neverTouchesGauge() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        assertEq(_gauge.balanceOf(_portfolioAccount), 0, "precondition: gauge empty");

        // Mock revert if gauge.withdraw is called — proves the path is not taken.
        // We can't easily expect-no-call in forge, so rely on getStakingState delta
        // and verify gauge balance is unchanged at zero.
        uint256 userBefore = _lp.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        assertEq(_lp.balanceOf(_user) - userBefore, DEPOSIT_AMOUNT, "user received from direct LP");
        assertEq(_gauge.balanceOf(_portfolioAccount), 0, "gauge untouched");
    }
}
