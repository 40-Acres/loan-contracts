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
 * @dev Tests for the collateral-neutrality guard in YieldBasisLpFacet.setStakedMode().
 *
 *  BUG UNDER TEST
 *  --------------
 *  The stake branch used to deposit LP into the gauge with NO collateral
 *  reconciliation or enforcement, so a gauge that minted fewer recoverable
 *  shares than LP sent silently dropped recoverable collateral while tracked
 *  `data.shares` / `data.debt` stayed unchanged.
 *
 *  FIX
 *  ---
 *  Two guards, both in the facet:
 *    1. `_stake` rejects any lossy gauge deposit outright --
 *       `require(convertToAssets(sharesMinted) >= lpSent, "Lossy stake")`.
 *       Neutrality is verified, not assumed, so a lossy stake ALWAYS reverts
 *       regardless of debt or borrow buffer.
 *    2. The stake branch still snapshots the shortfall baseline before _stake
 *       and reconciles + enforces after, guarding pre-existing gauge drift.
 *
 *  The tunable gauge's setDepositFeeBps(N) makes deposit(assets) mint
 *  assets*(10000-N)/10000 shares while keeping all LP and leaving convertRatioBps
 *  at 1:1, so convertToAssets(sharesMinted) = sharesMinted < lpSent — recoverable
 *  collateral drops by N bps on stake, which the guard now rejects.
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
    // Test 1: lossy stake at the LTV limit -> reverts
    // ============================================================

    /**
     * @notice At the LTV limit, a lossy stake would drop recoverable collateral
     *         below what the debt requires. The `_stake` neutrality guard rejects
     *         it outright with "Lossy stake" before any state is committed.
     */
    function test_setStakedMode_lossyStake_atLtvLimit_reverts() public {
        // Deposit 10e8, held unstaked.
        _depositLP(DEPOSIT_AMOUNT);

        // Borrow exactly max: position sits precisely at the LTV limit.
        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);

        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan (exactly at the limit)");
        assertGt(debt, 0, "Sanity: there must be debt");

        // Make the gauge lossy: deposit mints 99% of LP as recoverable shares.
        vm.prank(_owner);
        _gauge.setDepositFeeBps(100); // 1% loss

        // Inline the two pranks of _syncAndSetStake so vm.expectRevert sits
        // immediately before the setStakedMode() call.
        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(true);

        // The neutrality guard in _stake rejects the lossy deposit outright.
        vm.expectRevert(bytes("Lossy stake"));
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 2: lossy stake with borrow buffer -> still reverts
    // ============================================================

    /**
     * @notice The neutrality guard is unconditional: a lossy stake reverts even
     *         well below the LTV limit, where a borrow buffer would absorb the
     *         loss. Neutrality is verified, not tolerated.
     */
    function test_setStakedMode_lossyStake_withBuffer_reverts() public {
        _depositLP(DEPOSIT_AMOUNT);

        // Borrow well below max (max is 7e8; borrow 3e8).
        _borrow(3e8);

        vm.prank(_owner);
        _gauge.setDepositFeeBps(100); // 1% loss

        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(true);

        vm.expectRevert(bytes("Lossy stake"));
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 3: lossy stake with zero debt -> still reverts
    // ============================================================

    /**
     * @notice The neutrality guard is debt-agnostic: a lossy stake reverts even
     *         with no debt, since it is enforced in _stake before any shortfall
     *         computation.
     */
    function test_setStakedMode_lossyStake_zeroDebt_reverts() public {
        _depositLP(DEPOSIT_AMOUNT);

        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Precondition: no debt");

        vm.prank(_owner);
        _gauge.setDepositFeeBps(100); // 1% loss

        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(true);

        vm.expectRevert(bytes("Lossy stake"));
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
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
     * @notice De-risking (unstake) must stay lenient to PRE-EXISTING
     *         undercollateralization. The unstake branch now ALSO enforces
     *         collateral-neutrality, but with a fresh per-block baseline an
     *         underwater-but-honest unstake is neutral (end == start), so it must
     *         NOT revert -- it only rejects an unstake that REALIZES NEW loss
     *         (covered by test_setStakedMode_lossyUnstake_atLtvLimit_reverts).
     *         Passes on CURRENT code (unstake never reverts) and after the fix.
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

        // Fresh block so the unstake snapshots the (already-underwater) shortfall
        // as its baseline; an honest redeem realizes no new loss (end == start).
        vm.roll(block.number + 1);

        // Unstake must SUCCEED despite being underwater (pre-existing shortfall
        // is tolerated; only newly-realized loss is rejected).
        _syncAndSetStake(false);

        (uint256 stakedAfterUnstake, uint256 unstakedAfterUnstake) =
            YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfterUnstake, 0, "Should have 0 staked after unstake");
        assertGt(unstakedAfterUnstake, 0, "LP should be back on the account after unstake");
    }

    // ============================================================
    // Test 6: lossy-redeem unstake at the LTV limit -> must revert (GAP)
    // ============================================================

    /**
     * @notice At the LTV limit, an unstake whose gauge.redeem() delivers fewer LP
     *         than convertToAssets(shares) implied REALIZES new loss: reconcile
     *         ratchets tracked collateral down, dropping maxLoan below the debt.
     *         The unstake branch must snapshot a per-block baseline and enforce
     *         collateral-neutrality, reverting UndercollateralizedDebt(700000).
     *
     *         GAP (current code): the unstake branch takes NO shortfall baseline
     *         and runs NO enforce, so it silently writes down collateral without
     *         reverting. This test therefore FAILS on current code with "call did
     *         not revert as expected" -- that failure IS the bug. The src fix
     *         (snapshot -> redeem -> reconcile -> enforce on the unstake branch)
     *         flips it to passing.
     */
    function test_setStakedMode_lossyUnstake_atLtvLimit_reverts() public {
        // Deposit 10e8, held unstaked.
        _depositLP(DEPOSIT_AMOUNT);

        // Stake lossless (honest 1:1) so there are gauge shares to unstake.
        _syncAndSetStake(true);
        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertGt(staked, 0, "Precondition: LP staked lossless");

        // Borrow exactly max: position sits precisely at the LTV limit.
        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan (exactly at the limit)");
        assertGt(debt, 0, "Sanity: there must be debt");

        // Make redeem lossy: delivers convertToAssets(shares) - 1e6 LP (0.01 LP
        // loss). convertToAssets stays honest 1:1, so reconcile ratchets tracked
        // collateral down by 1e6 and maxLoan drops by 0.7 * 1e6 = 700000 ->
        // shortfall becomes 700000 (nonzero).
        vm.prank(_owner);
        _gauge.setRedeemShortfallWei(1e6);

        // Flip the protocol directive to unstaked.
        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(false);

        // Fresh block so the unstake snapshots its own (healthy) baseline, then
        // realizes the redeem loss within the same block -> end > start.
        vm.roll(block.number + 1);

        // Exact delta computes to 700000 (verified: debt 7e8 vs maxLoan 699_300_000).
        vm.expectRevert(
            abi.encodeWithSelector(YieldBasisCollateralManager.UndercollateralizedDebt.selector, 700000)
        );
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 7: lossless-redeem unstake at the limit across a fresh block -> succeeds
    // ============================================================

    /**
     * @notice An honest 1:1 unstake at the LTV limit must NOT revert. With a fresh
     *         per-block baseline the unstake realizes no new loss (end == start),
     *         so collateral-neutrality holds. Guards the upcoming unstake-branch
     *         enforce against over-strictness; passes on current code too.
     */
    function test_setStakedMode_losslessUnstake_atLtvLimit_succeeds() public {
        _depositLP(DEPOSIT_AMOUNT);

        _syncAndSetStake(true);
        (uint256 stakedBefore, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertGt(stakedBefore, 0, "Precondition: LP staked lossless");

        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), maxLoan, "Debt at the limit");

        // redeemShortfallWei stays 0 -> honest 1:1 redeem.
        vm.prank(_owner);
        _portfolioFactoryConfig.setStakedGaugeMode(false);

        // Fresh block: honest unstake is neutral (end == start).
        vm.roll(block.number + 1);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).setStakedMode();

        (uint256 stakedAfter, uint256 unstakedAfter) =
            YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfter, 0, "Should have 0 staked after honest unstake");
        assertGt(unstakedAfter, 0, "LP should be back on the account after unstake");
    }
}
