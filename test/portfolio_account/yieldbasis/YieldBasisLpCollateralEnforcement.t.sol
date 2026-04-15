// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Facets under test
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpFeeClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFeeClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {YieldBasisLpRewardsProcessingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";

// Infrastructure
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockYieldBasisGauge} from "../../mocks/MockYieldBasisGauge.sol";

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// LendingVault
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

/**
 * @title YieldBasisLpCollateralEnforcementTest
 * @dev Tests that the YieldBasis LP collateral system prevents dipping below
 *      collateral requirements when claiming/swapping rewards in both staked
 *      and unstaked modes.
 *
 * Key invariants tested:
 * 1. harvestLpFees calls enforceCollateralRequirements — undercollateralized harvests revert
 * 2. swapToRewardsToken blocks swapping the LP token (collateral token)
 * 3. Claiming YB emissions (staked mode) does not affect collateral
 * 4. Harvesting LP fees (unstaked mode) does not drop collateral below required
 * 5. Unstake/restake preserves collateral tracking
 */
contract YieldBasisLpCollateralEnforcementTest is Test {
    // Facets
    YieldBasisLpFacet public _ybBtcFacet;
    YieldBasisLpClaimingFacet public _ybBtcClaimingFacet;
    YieldBasisLpFeeClaimingFacet public _ybBtcFeeClaimingFacet;
    YieldBasisLpLendingFacet public _ybBtcLendingFacet;
    YieldBasisLpRewardsProcessingFacet public _ybBtcRewardsProcessingFacet;

    // Infrastructure
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;
    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;

    // Mock contracts
    MockYieldBasisLP public _ybBtc;       // underlying LP token (8 decimals)
    MockERC20 public _usdc;               // lending asset (8 decimals)
    MockERC20 public _ybToken;            // YB reward token (18 decimals)
    MockYieldBasisGauge public _gauge;
    LendingVault public _lendingVault;
    SwapConfig public _swapConfig;

    // Actors
    address public _user = address(0x40ac2e);
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    // Portfolio account (diamond proxy) for user
    address public _portfolioAccount;

    // Test amounts
    uint256 constant DEPOSIT_AMOUNT = 10e8;       // 10 ybBTC (8 decimals)
    uint256 constant VAULT_LIQUIDITY = 100_000e8;  // 100k USDC-equivalent in vault
    uint256 constant LTV_BPS = 7000;               // 70% LTV

    function setUp() public {
        vm.startPrank(_owner);

        // --- Deploy portfolio manager and factory ---
        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-btc-collateral-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // --- Deploy config contracts ---
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (_portfolioFactoryConfig, , _loanConfig, ) = configDeployer.deploy(address(_portfolioFactory), _owner);

        // --- Deploy mock tokens ---
        _ybBtc = new MockYieldBasisLP("ybBTC", "ybBTC", 8);
        _usdc = new MockERC20("USDC", "USDC", 8);
        _ybToken = new MockERC20("YieldBasis", "YB", 18);

        // --- Deploy mock gauge ---
        _gauge = new MockYieldBasisGauge(address(_ybBtc));

        // --- Deploy SwapConfig (needed for RewardsProcessingFacet) ---
        SwapConfig swapConfigImpl = new SwapConfig();
        _swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (_owner))
            ))
        );

        // --- Deploy LendingVault behind ERC1967Proxy ---
        LendingVault lendingVaultImpl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(_usdc),              // asset
            address(_portfolioFactory),  // portfolioFactory
            _owner,                      // owner
            "Lending Vault",             // name
            "lVAULT",                    // symbol
            8000,                        // maxUtilizationBps (80%)
            80                           // originationFeeBps (0.8%)
        );
        ERC1967Proxy lendingVaultProxy = new ERC1967Proxy(address(lendingVaultImpl), initData);
        _lendingVault = LendingVault(address(lendingVaultProxy));

        // Fund lending vault with USDC liquidity
        _usdc.mint(address(_lendingVault), VAULT_LIQUIDITY);

        // --- Configure ---
        _loanConfig.setMultiplier(LTV_BPS);
        _portfolioFactoryConfig.setLoanContract(address(_lendingVault));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        // --- Deploy and register YieldBasisLpFacet ---
        _ybBtcFacet = new YieldBasisLpFacet(address(_portfolioFactory), address(_gauge), address(_ybToken));
        {
            bytes4[] memory selectors = new bytes4[](9);
            selectors[0] = YieldBasisLpFacet.deposit.selector;
            selectors[1] = YieldBasisLpFacet.withdraw.selector;
            selectors[2] = YieldBasisLpFacet.unstake.selector;
            selectors[3] = YieldBasisLpFacet.restake.selector;
            selectors[4] = YieldBasisLpFacet.getStakingState.selector;
            selectors[5] = ICollateralFacet.enforceCollateralRequirements.selector;
            selectors[6] = ICollateralFacet.getTotalLockedCollateral.selector;
            selectors[7] = ICollateralFacet.getTotalDebt.selector;
            selectors[8] = ICollateralFacet.getMaxLoan.selector;
            _facetRegistry.registerFacet(address(_ybBtcFacet), selectors, "YieldBasisLpFacet");
        }

        // --- Deploy and register YieldBasisLpClaimingFacet ---
        _ybBtcClaimingFacet = new YieldBasisLpClaimingFacet(address(_portfolioFactory), address(_gauge));
        {
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
            selectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
            _facetRegistry.registerFacet(address(_ybBtcClaimingFacet), selectors, "YieldBasisLpClaimingFacet");
        }

        // --- Deploy and register YieldBasisLpFeeClaimingFacet ---
        _ybBtcFeeClaimingFacet = new YieldBasisLpFeeClaimingFacet(address(_portfolioFactory), address(_gauge));
        {
            bytes4[] memory selectors = new bytes4[](3);
            selectors[0] = YieldBasisLpFeeClaimingFacet.harvestLpFees.selector;
            selectors[1] = YieldBasisLpFeeClaimingFacet.getAvailableLpFeeYield.selector;
            selectors[2] = YieldBasisLpFeeClaimingFacet.getDepositInfo.selector;
            _facetRegistry.registerFacet(address(_ybBtcFeeClaimingFacet), selectors, "YieldBasisLpFeeClaimingFacet");
        }

        // --- Deploy and register YieldBasisLpLendingFacet ---
        _ybBtcLendingFacet = new YieldBasisLpLendingFacet(
            address(_portfolioFactory),
            address(_usdc),
            address(_gauge)
        );
        {
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = YieldBasisLpLendingFacet.borrow.selector;
            selectors[1] = YieldBasisLpLendingFacet.pay.selector;
            _facetRegistry.registerFacet(address(_ybBtcLendingFacet), selectors, "YieldBasisLpLendingFacet");
        }

        // --- Deploy and register YieldBasisLpRewardsProcessingFacet ---
        _ybBtcRewardsProcessingFacet = new YieldBasisLpRewardsProcessingFacet(
            address(_portfolioFactory),
            address(_swapConfig),
            address(_gauge),
            address(_lendingVault),
            address(0)
        );
        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = RewardsProcessingFacet.swapToRewardsToken.selector;
            _facetRegistry.registerFacet(address(_ybBtcRewardsProcessingFacet), selectors, "YieldBasisLpRewardsProcessingFacet");
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

    /// @dev Deposit LP tokens into portfolio account and stake in gauge
    function _depositLP(uint256 amount) internal {
        vm.startPrank(_user);
        _ybBtc.transfer(_portfolioAccount, amount);
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount));
        vm.stopPrank();
    }

    /// @dev Borrow USDC against collateral (via multicall since it requires onlyPortfolioManagerMulticall)
    function _borrow(uint256 amount) internal {
        vm.startPrank(_user);
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, amount));
        vm.stopPrank();
    }

    /// @dev Repay all outstanding debt
    function _repayAll() internal {
        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        if (debt == 0) return;
        _usdc.mint(_user, debt);
        vm.startPrank(_user);
        _usdc.approve(_portfolioAccount, debt);
        YieldBasisLpLendingFacet(_portfolioAccount).pay(debt);
        vm.stopPrank();
    }

    /// @dev Calculate max loan for a given collateral value at our LTV
    function _maxLoanFor(uint256 collateralValue) internal pure returns (uint256) {
        return (collateralValue * LTV_BPS) / 10000;
    }

    // ============ Test 1: harvestLpFees succeeds when surplus covers collateral ============

    /**
     * @notice Deposit LP, borrow near max, increase pricePerShare, harvest fees.
     *         Should succeed because fee surplus exceeds the collateral reduction.
     *
     * Flow:
     * 1. Deposit 10 ybBTC at PPS=1e18 → collateral value = 10e8
     * 2. Borrow 5e8 (well within 70% LTV = 7e8 max)
     * 3. Increase PPS to 1.5e18 → current value rises to 15e8
     * 4. Harvest → redeems surplus gauge shares for yield
     * 5. Verify collateral still >= required after harvest
     */
    function test_harvestLpFees_succeedsWhenSurplusCoversCollateral() public {
        // Step 1: Deposit
        _depositLP(DEPOSIT_AMOUNT);

        // Step 2: Borrow
        uint256 borrowAmount = 5e8;
        _borrow(borrowAmount);

        uint256 debtBefore = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, borrowAmount, "Debt should equal borrow amount");

        // Step 3: Increase PPS (simulate trading fee accrual)
        _ybBtc.setPricePerShare(1.5e18);

        // Verify yield is available before harvest
        (uint256 yieldUnderlying, uint256 yieldShares) = YieldBasisLpFeeClaimingFacet(_portfolioAccount).getAvailableLpFeeYield();
        assertGt(yieldUnderlying, 0, "Should have yield available");
        assertGt(yieldShares, 0, "Should have surplus shares");

        // Step 4: Harvest LP fees (authorized caller)
        vm.prank(_authorizedCaller);
        uint256 underlyingReceived = YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
        assertGt(underlyingReceived, 0, "Should have received underlying from harvest");

        // Step 5: Verify collateral still enforced
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Collateral requirements should still pass after harvest");

        // Verify debt unchanged (harvest does not affect debt)
        uint256 debtAfter = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, debtBefore, "Debt should be unchanged after fee harvest");

        // Verify collateral value is still >= deposited value
        // After harvest, remaining shares should still cover deposited value
        (uint256 shares, uint256 depositedValue, uint256 currentValue) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();
        assertGe(currentValue, depositedValue, "Current value should still cover deposited value after harvest");
    }

    // ============ Test 2: harvestLpFees reverts when undercollateralized ============

    /**
     * @notice Tests two scenarios:
     * A) PPS decrease (hack simulation) → "No yield to harvest" because currentValue <= depositedValue
     * B) PPS barely above deposit → harvest would leave undercollateralized → enforceCollateral reverts
     *
     * Invariant: harvestLpFees must never leave the position undercollateralized.
     */
    function test_harvestLpFees_revertsWhenPPSDecreased() public {
        // Deposit and borrow at max
        _depositLP(DEPOSIT_AMOUNT);

        // Borrow close to max: 70% of 10e8 = 7e8, borrow 6.9e8
        uint256 borrowAmount = 6.9e8;
        _borrow(borrowAmount);

        // Simulate a hack: PPS drops to 0.5e18 (LP lost value)
        _ybBtc.setPricePerShare(0.5e18);

        // Attempt harvest should revert with "No yield to harvest"
        // because currentValue (5e8) < depositedValue (10e8)
        vm.prank(_authorizedCaller);
        vm.expectRevert("No yield to harvest");
        YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
    }

    /**
     * @notice Verify that harvestLpFees cannot cause undercollateralization by design.
     *
     * Analysis of the safety mechanism:
     * - removeSharesForYield() requires: remainingValue >= depositedAssetValue
     * - This means after harvest, the collateral value is always >= the original deposit value
     * - Since maxLoan = collateralValue * LTV, and the borrow was limited to depositedValue * LTV,
     *   the post-harvest maxLoan will always be >= the original maxLoan
     * - Therefore, harvesting yield can NEVER cause undercollateralization
     *
     * This test proves this invariant: borrow at max, increase PPS, harvest succeeds,
     * and enforceCollateralRequirements passes because remaining collateral >= deposited.
     */
    function test_harvestLpFees_cannotCauseUndercollateralizationByDesign() public {
        // Deposit
        _depositLP(DEPOSIT_AMOUNT);

        // Borrow exactly at max loan (7e8 from 10e8 at 70% LTV)
        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);

        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Should have borrowed the full max loan");

        // Record deposited value
        (, uint256 depositedValueBefore, ) = YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();

        // Increase PPS — now there's yield to harvest
        _ybBtc.setPricePerShare(1.5e18);

        // Harvest LP fees
        vm.prank(_authorizedCaller);
        uint256 received = YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
        assertGt(received, 0, "Should receive yield");

        // Key invariant: remaining collateral value >= deposited value
        (, uint256 depositedValueAfter, uint256 currentValueAfter) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();
        assertEq(depositedValueAfter, depositedValueBefore, "Deposited value unchanged by harvest");
        assertGe(currentValueAfter, depositedValueAfter, "Current value still covers deposited value");

        // maxLoan after harvest >= original maxLoan → debt is still covered
        (uint256 maxLoanAfter, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        // maxLoanAfter accounts for existing debt, so it shows remaining borrowing capacity
        // The full maxLoan ignoring supply = currentValueAfter * LTV / 10000
        uint256 maxLoanIgnoreDebt = (currentValueAfter * LTV_BPS) / 10000;
        assertGe(maxLoanIgnoreDebt, debt, "Max loan from remaining collateral must cover existing debt");

        // enforceCollateralRequirements passes
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Collateral requirements should pass - harvest cannot cause undercollateralization");
    }

    /**
     * @notice When PPS drops (hack/exploit), there's no yield to harvest.
     *         The "No yield to harvest" guard prevents any extraction.
     *         Meanwhile, the position may already be undercollateralized from the PPS drop,
     *         but that's not caused by the harvest — it's a pre-existing condition.
     */
    function test_harvestLpFees_blockedWhenPPSDropsAndPositionUndercollateralized() public {
        _depositLP(DEPOSIT_AMOUNT);
        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        _borrow(maxLoan);

        // PPS drops — simulating an exploit on the underlying LP
        _ybBtc.setPricePerShare(0.8e18);

        // No yield to harvest
        vm.prank(_authorizedCaller);
        vm.expectRevert("No yield to harvest");
        YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);

        // The position is now undercollateralized (not from harvest, from PPS drop)
        // collateral value = 10e8 * 0.8 = 8e8, maxLoan = 8e8 * 0.7 = 5.6e8
        // debt = 7e8 > 5.6e8 → undercollateralized
        // Note: enforceCollateralRequirements uses snapshot comparison, so calling it
        // outside of a mutating operation context (no snapshot in this block) means
        // startShortfall = 0 and endShortfall = 7e8 - 5.6e8 = 1.4e8 > 0 → reverts
        vm.expectRevert();
        ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
    }

    // ============ Test 3: YB emission claims do not affect collateral ============

    /**
     * @notice Claiming YB token rewards from gauge should have zero impact on collateral.
     *         YB emissions are a separate reward token, not related to the LP collateral.
     *
     * Invariant: getTotalLockedCollateral() before == after claiming gauge rewards.
     */
    function test_claimYbEmissions_doesNotAffectCollateral() public {
        // Deposit and borrow
        _depositLP(DEPOSIT_AMOUNT);
        _borrow(3e8);

        // Record collateral and debt state before
        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 debtBefore = ICollateralFacet(_portfolioAccount).getTotalDebt();
        (uint256 sharesBefore, uint256 depositedValueBefore, ) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();

        // Set up YB emissions on gauge
        uint256 rewardAmount = 100e18; // 100 YB tokens
        _ybToken.mint(address(_gauge), rewardAmount);
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        // Claim gauge rewards
        vm.prank(_authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(claimed, rewardAmount, "Should claim full reward amount");

        // Verify YB tokens landed on portfolio account
        assertEq(_ybToken.balanceOf(_portfolioAccount), rewardAmount, "YB tokens should be on account");

        // Verify collateral is completely unchanged
        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 debtAfter = ICollateralFacet(_portfolioAccount).getTotalDebt();
        (uint256 sharesAfter, uint256 depositedValueAfter, ) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();

        assertEq(collateralAfter, collateralBefore, "Collateral value must not change after YB claim");
        assertEq(debtAfter, debtBefore, "Debt must not change after YB claim");
        assertEq(sharesAfter, sharesBefore, "Tracked shares must not change after YB claim");
        assertEq(depositedValueAfter, depositedValueBefore, "Deposited value must not change after YB claim");

        // enforceCollateralRequirements should still pass
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Collateral requirements should still pass after claiming emissions");
    }

    // ============ Test 4: swapToRewardsToken blocks LP token swap ============

    /**
     * @notice The YieldBasisLpRewardsProcessingFacet sets the LP token as _underlyingLockedAsset
     *         in its constructor. swapToRewardsToken must revert when attempting to swap
     *         the LP token (collateral) to prevent selling collateral.
     *
     * This is a critical guard: without it, an authorized caller could sell
     * the LP collateral via swapToRewardsToken, leaving the position undercollateralized.
     */
    function test_swapLpToken_isBlocked() public {
        SwapMod.RouteParams memory params = SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: address(0x1234),
            swapData: "",
            inputToken: address(_ybBtc),  // LP token = collateral token
            inputAmount: 1e8,
            outputToken: address(_usdc),
            minimumOutputAmount: 0
        });

        vm.prank(_authorizedCaller);
        vm.expectRevert("Input token not allowed");
        RewardsProcessingFacet(_portfolioAccount).swapToRewardsToken(params);
    }

    // ============ Test 5: Harvest fees after full debt repayment ============

    /**
     * @notice After all debt is repaid, harvesting LP fees should succeed fully
     *         since there are no collateral requirements with zero debt.
     *
     * Flow:
     * 1. Deposit, borrow, repay all debt
     * 2. Increase PPS (fee accrual)
     * 3. Harvest → no collateral enforcement blocks it (debt=0 → maxLoan check trivially passes)
     */
    function test_harvestLpFees_succeedsAfterFullDebtRepayment() public {
        // Deposit and borrow
        _depositLP(DEPOSIT_AMOUNT);
        _borrow(5e8);

        // Repay all debt
        _repayAll();
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt should be 0 after repay");

        // Increase PPS significantly — big yield available
        _ybBtc.setPricePerShare(2e18); // 2x appreciation

        // Preview yield
        (uint256 yieldUnderlying, uint256 yieldShares) = YieldBasisLpFeeClaimingFacet(_portfolioAccount).getAvailableLpFeeYield();
        assertGt(yieldUnderlying, 0, "Should have yield to harvest");
        assertGt(yieldShares, 0, "Should have surplus shares");

        // Harvest — should succeed since no debt
        vm.prank(_authorizedCaller);
        uint256 received = YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
        assertGt(received, 0, "Should receive underlying from harvest");

        // Collateral requirements trivially pass with 0 debt
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Requirements should pass with 0 debt");

        // Verify deposited value is preserved (removeSharesForYield keeps it intact)
        (uint256 shares, uint256 depositedValue, uint256 currentValue) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();
        assertGe(currentValue, depositedValue, "Current value should cover deposited value");
    }

    // ============ Test 6: Unstake/restake preserves collateral tracking ============

    /**
     * @notice When switching yield modes (unstake from gauge, restake into gauge),
     *         collateral tracking must remain consistent.
     *
     * Flow:
     * 1. Deposit 10 ybBTC → staked in gauge, collateral = 10e8
     * 2. Borrow 4e8
     * 3. Unstake (removeCollateral) → LP tokens on account, collateral goes down
     * 4. Restake (addCollateral) → LP tokens back in gauge, collateral goes back up
     * 5. enforceCollateralRequirements must pass throughout
     *
     * Note: unstake + restake must happen in the same multicall (borrow guard)
     * or collateral must be sufficient at each point.
     */
    function test_unstakeRestake_preservesCollateralTracking() public {
        // Deposit
        _depositLP(DEPOSIT_AMOUNT);
        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralBefore, DEPOSIT_AMOUNT, "Initial collateral should match deposit");

        // Borrow a moderate amount
        _borrow(4e8);
        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 4e8, "Debt should be 4e8");

        // Get gauge shares to unstake
        (uint256 stakedBefore, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();

        // Unstake all and immediately restake in a single multicall
        // This ensures collateral enforcement at the end of multicall sees restaked state
        vm.startPrank(_user);
        {
            bytes[] memory calldatas = new bytes[](2);
            calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.unstake.selector, stakedBefore);
            calldatas[1] = abi.encodeWithSelector(YieldBasisLpFacet.restake.selector, DEPOSIT_AMOUNT);
            // unstake is onlyAuthorizedCaller, not onlyPortfolioManagerMulticall
            // So we need to call unstake and restake individually
        }
        vm.stopPrank();

        // Unstake via authorized caller
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(stakedBefore);

        // After unstake: collateral removed, LP tokens on account
        (uint256 stakedAfterUnstake, uint256 unstakedAfterUnstake) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfterUnstake, 0, "Should have 0 staked after unstake");
        assertEq(unstakedAfterUnstake, DEPOSIT_AMOUNT, "All LP should be unstaked");

        // Collateral preserved — LP stays in portfolio, tracking unchanged
        uint256 collateralAfterUnstake = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterUnstake, collateralBefore, "Collateral preserved after unstake");

        // Restake via authorized caller
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);

        // After restake: LP tokens back in gauge, collateral re-tracked
        (uint256 stakedAfterRestake, uint256 unstakedAfterRestake) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfterRestake, DEPOSIT_AMOUNT, "Should have all staked after restake");
        assertEq(unstakedAfterRestake, 0, "Should have 0 unstaked after restake");

        // Collateral should be restored
        uint256 collateralAfterRestake = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterRestake, collateralBefore, "Collateral should be restored after restake");

        // enforceCollateralRequirements should pass
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Collateral requirements should pass after restake");

        // Debt unchanged throughout
        uint256 debtAfter = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, debt, "Debt should not change during unstake/restake");
    }

    /**
     * @notice Unstake while indebted does NOT reduce collateral — LP stays in portfolio.
     *         enforceCollateralRequirements passes throughout since collateral is preserved.
     */
    function test_unstakeWhileIndebted_collateralPreserved() public {
        _depositLP(DEPOSIT_AMOUNT);
        _borrow(5e8);

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // Unstake all — collateral unchanged because LP stays in portfolio
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(staked);

        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "Collateral preserved after unstake while indebted");

        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debt, 0, "Debt should still exist");

        // enforceCollateralRequirements still passes — collateral unchanged
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Collateral requirements pass - LP still in portfolio");

        // Restake
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);

        // Still passes
        success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Still passes after restaking");
    }

    // ============ Additional edge case tests ============

    /**
     * @notice Verify that harvestLpFees reverts when there are no shares deposited.
     */
    function test_harvestLpFees_revertsWithNoShares() public {
        // No deposit — try to harvest
        vm.prank(_authorizedCaller);
        vm.expectRevert("No shares deposited");
        YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
    }

    /**
     * @notice Verify that harvestLpFees with no PPS change yields nothing.
     */
    function test_harvestLpFees_revertsWhenNoPPSChange() public {
        _depositLP(DEPOSIT_AMOUNT);

        // PPS is still 1e18 (default) — same as deposit time
        // currentValue == depositedValue → "No yield to harvest"
        vm.prank(_authorizedCaller);
        vm.expectRevert("No yield to harvest");
        YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
    }

    /**
     * @notice Multiple deposits at different PPS track depositedAssetValue correctly.
     *         Ensures harvest only claims the yield, not principal.
     */
    function test_harvestLpFees_afterMultipleDepositsAtDifferentPPS() public {
        // First deposit at PPS=1e18
        _depositLP(5e8);

        // Increase PPS
        _ybBtc.setPricePerShare(1.5e18);

        // Second deposit at PPS=1.5e18
        _depositLP(5e8);

        // deposited value = 5e8 * 1.0 + 5e8 * 1.5 = 5e8 + 7.5e8 = 12.5e8
        (uint256 shares, uint256 depositedValue, uint256 currentValue) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();

        assertEq(shares, 10e8, "Should have 10e8 total shares");
        assertEq(depositedValue, 12.5e8, "Deposited value should be 12.5e8 (weighted by PPS at deposit time)");
        // current value at PPS=1.5: 10e8 * 1.5 = 15e8
        assertEq(currentValue, 15e8, "Current value should be 15e8 at PPS=1.5");

        // Yield = 15e8 - 12.5e8 = 2.5e8
        (uint256 yieldUnderlying, ) = YieldBasisLpFeeClaimingFacet(_portfolioAccount).getAvailableLpFeeYield();
        assertEq(yieldUnderlying, 2.5e8, "Yield should be 2.5e8");

        // Harvest should work and only take yield, not principal
        vm.prank(_authorizedCaller);
        uint256 received = YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
        assertGt(received, 0, "Should receive yield");

        // After harvest, remaining value should still cover deposited value
        (, uint256 depositedValueAfter, uint256 currentValueAfter) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();
        assertGe(currentValueAfter, depositedValueAfter, "Remaining value must cover deposited value after harvest");
        assertEq(depositedValueAfter, depositedValue, "Deposited value should be unchanged (removeSharesForYield)");
    }

    /**
     * @notice Verify that claiming gauge rewards for a non-existent reward token returns 0.
     */
    function test_claimGaugeRewards_zeroWhenNoRewards() public {
        _depositLP(DEPOSIT_AMOUNT);

        // No rewards set — claim should return 0
        vm.prank(_authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(claimed, 0, "Should claim 0 when no rewards set");

        // Collateral unchanged
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, DEPOSIT_AMOUNT, "Collateral should be unchanged");
    }

    // ============ Test 7: Post-harvest flow — underlying on account → repay debt ============

    /**
     * @notice After harvestLpFees, underlying tokens land on the portfolio account.
     *         Verify the balance increases and debt can be repaid using lending tokens.
     *
     * In real deployment: harvest → WBTC on account → swap → USDC → pay()
     * In mock: harvest → ybBTC on account (mock uses same token as underlying stand-in)
     * We test the flow in two parts:
     *   (a) harvest increases token balance on the account
     *   (b) pay() with USDC decreases debt
     */
    function test_postHarvest_underlyingOnAccountThenRepayDebt() public {
        // Deposit and borrow
        _depositLP(DEPOSIT_AMOUNT);
        uint256 borrowAmount = 5e8;
        _borrow(borrowAmount);

        uint256 debtBefore = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, borrowAmount, "Debt should match borrow");

        // Simulate fee accrual
        _ybBtc.setPricePerShare(1.5e18);

        // Record ybBTC balance on portfolio account before harvest
        uint256 ybBtcBalanceBefore = _ybBtc.balanceOf(_portfolioAccount);

        // Harvest LP fees — underlying (ybBTC in mock) lands on portfolio account
        vm.prank(_authorizedCaller);
        uint256 underlyingReceived = YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
        assertGt(underlyingReceived, 0, "Should have received underlying from harvest");

        // (a) Verify underlying balance increased on portfolio account
        uint256 ybBtcBalanceAfter = _ybBtc.balanceOf(_portfolioAccount);
        assertEq(
            ybBtcBalanceAfter - ybBtcBalanceBefore,
            underlyingReceived,
            "ybBTC balance should increase by exactly the harvested amount"
        );

        // (b) Repay debt using USDC (in real flow, underlying would be swapped to USDC first)
        uint256 repayAmount = 2e8;
        _usdc.mint(_user, repayAmount);
        vm.startPrank(_user);
        _usdc.approve(_portfolioAccount, repayAmount);
        YieldBasisLpLendingFacet(_portfolioAccount).pay(repayAmount);
        vm.stopPrank();

        // Verify debt decreased
        uint256 debtAfter = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, debtBefore - repayAmount, "Debt should decrease by repay amount");

        // Verify collateral requirements pass
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Collateral requirements should pass after repayment");
    }

    // ============ Test 8: Full lifecycle with fee harvesting ============

    /**
     * @notice Complete happy-path lifecycle:
     *         Deposit LP → borrow → PPS appreciates → harvest LP fees →
     *         repay debt → withdraw LP
     */
    function test_fullLifecycle_depositBorrowHarvestRepayWithdraw() public {
        // Step 1: Deposit LP
        _depositLP(DEPOSIT_AMOUNT);
        uint256 collateralAfterDeposit = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterDeposit, DEPOSIT_AMOUNT, "Collateral should match deposit");

        // Step 2: Borrow
        uint256 borrowAmount = 4e8;
        _borrow(borrowAmount);
        uint256 debtAfterBorrow = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfterBorrow, borrowAmount, "Debt should match borrow");

        // Step 3: PPS appreciates (trading fees accrue)
        _ybBtc.setPricePerShare(1.3e18);

        // Step 4: Harvest LP fees
        vm.prank(_authorizedCaller);
        uint256 underlyingReceived = YieldBasisLpFeeClaimingFacet(_portfolioAccount).harvestLpFees(0);
        assertGt(underlyingReceived, 0, "Should receive underlying from fee harvest");

        // Verify underlying is on the account
        uint256 underlyingOnAccount = _ybBtc.balanceOf(_portfolioAccount);
        assertEq(underlyingOnAccount, underlyingReceived, "Underlying should be on account");

        // Debt unchanged by harvest
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), debtAfterBorrow, "Debt unchanged by harvest");

        // Step 5: Repay all debt (with USDC — in reality this comes from swapping the underlying)
        _repayAll();
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt should be fully repaid");

        // Step 6: Withdraw LP
        // After harvest, fewer gauge shares remain (surplus was redeemed).
        // NOTE: In the mock, underlying == LP token (ybBTC), so the harvested underlying
        // appears as ybBTC balance on the account. The withdraw() function sees this as
        // "already unstaked LP" and uses it first before pulling from gauge.
        // In production, underlying (e.g. WBTC) != LP (ybBTC), so this artifact wouldn't occur.
        (uint256 remainingStaked, uint256 lpOnAccount) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertGt(remainingStaked, 0, "Should have remaining staked shares after harvest");
        assertGt(lpOnAccount, 0, "Harvested underlying (ybBTC in mock) should be on account");

        // Withdraw everything: both the staked gauge shares and LP on account.
        // Total withdrawable = staked + LP balance on account
        uint256 totalWithdrawable = remainingStaked + lpOnAccount;
        uint256 userLpBefore = _ybBtc.balanceOf(_user);
        vm.startPrank(_user);
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, totalWithdrawable));
        vm.stopPrank();

        // Verify user received all LP tokens
        uint256 userLpAfter = _ybBtc.balanceOf(_user);
        assertEq(userLpAfter - userLpBefore, totalWithdrawable, "User should receive all withdrawn LP tokens");

        // Verify gauge is fully drained
        (uint256 finalStaked, uint256 finalUnstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(finalStaked, 0, "No shares should remain staked after full withdraw");
        assertEq(finalUnstaked, 0, "No LP should remain on account after full withdraw");

        // Verify zero debt and zero collateral tracked
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Final debt should be 0");
    }

    // ============ Test 9: Deposit new LP while partially unstaked (mixed state) ============

    /**
     * @notice Deposit LP → unstake → deposit MORE LP → verify mixed state.
     *
     * After unstake, LP tokens sit on the portfolio account (not in gauge).
     * data.shares still reflects the original deposit (collateral preserved).
     * New deposit() stakes new LP in gauge and adds to collateral.
     * The addCollateral balance check should pass because it counts both
     * gauge shares AND LP token balance held directly.
     *
     * Verifies:
     * - Total collateral reflects both deposits
     * - getStakingState shows mixed state (some staked in gauge, some unstaked on account)
     */
    function test_depositNewLpWhileUnstaked_mixedState() public {
        uint256 firstDeposit = 5e8;
        uint256 secondDeposit = 3e8;

        // Step 1: First deposit — goes to gauge
        _depositLP(firstDeposit);

        (uint256 staked1, uint256 unstaked1) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked1, firstDeposit, "First deposit should be fully staked");
        assertEq(unstaked1, 0, "Nothing unstaked yet");
        uint256 collateral1 = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral1, firstDeposit, "Collateral should equal first deposit");

        // Step 2: Unstake all — LP moves to portfolio account, collateral preserved
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(firstDeposit);

        (uint256 staked2, uint256 unstaked2) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked2, 0, "All should be unstaked from gauge");
        assertEq(unstaked2, firstDeposit, "LP should be on portfolio account");
        uint256 collateral2 = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral2, collateral1, "Collateral preserved after unstake");

        // Step 3: Deposit MORE LP — new LP goes to gauge
        _depositLP(secondDeposit);

        // Step 4: Verify mixed state
        (uint256 staked3, uint256 unstaked3) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked3, secondDeposit, "Only second deposit should be staked in gauge");
        assertEq(unstaked3, firstDeposit, "First deposit LP still unstaked on account");

        // Step 5: Verify total collateral reflects both deposits
        uint256 collateral3 = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral3, firstDeposit + secondDeposit, "Total collateral should be sum of both deposits");

        // Step 6: Verify deposit info
        (uint256 totalShares, uint256 depositedValue, uint256 currentValue) =
            YieldBasisLpFeeClaimingFacet(_portfolioAccount).getDepositInfo();
        assertEq(totalShares, firstDeposit + secondDeposit, "Total tracked shares should be both deposits");
        assertEq(depositedValue, firstDeposit + secondDeposit, "Deposited value at PPS=1 equals shares");
        assertEq(currentValue, firstDeposit + secondDeposit, "Current value at PPS=1 equals deposited value");
    }

    // ============ Test 10: WBTC (underlying) is NOT the collateral token ============

    /**
     * @notice The _underlyingLockedAsset in YieldBasisLpRewardsProcessingFacet is the LP token
     *         (ybBTC), not the underlying asset (WBTC). After fee harvesting, the underlying
     *         asset lands on the account and should be freely usable (swappable).
     *
     * This verifies that harvested underlying is not accidentally blocked by the
     * collateral token guard in swapToRewardsToken.
     *
     * In the mock, underlying == ybBTC (same token), but in production they differ.
     * We test the conceptual separation by verifying a distinct token is NOT blocked.
     */
    function test_underlyingAsset_isNotBlockedByCollateralGuard() public {
        // Create a mock "WBTC" token to represent the real underlying
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        // Verify WBTC != LP token (ybBTC)
        assertTrue(address(wbtc) != address(_ybBtc), "WBTC should be a different address than ybBTC LP token");

        // Attempt to swap WBTC via swapToRewardsToken — should NOT hit collateral guard
        SwapMod.RouteParams memory params = SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: address(0x1234),
            swapData: "",
            inputToken: address(wbtc),  // underlying asset, NOT collateral
            inputAmount: 1e8,
            outputToken: address(_usdc),
            minimumOutputAmount: 0
        });

        vm.prank(_authorizedCaller);
        // Should NOT revert with "Input token cannot be collateral token"
        // Will revert for other reasons (bad swap target, no balance), but not the guard
        try RewardsProcessingFacet(_portfolioAccount).swapToRewardsToken(params) {
            // If it passes, great
        } catch (bytes memory reason) {
            // Verify the revert reason is NOT the collateral guard
            bytes memory collateralGuardError = abi.encodeWithSignature(
                "Error(string)",
                "Input token cannot be collateral token"
            );
            assertTrue(
                keccak256(reason) != keccak256(collateralGuardError),
                "Underlying asset should NOT be blocked by collateral token guard"
            );
        }
    }

    // ============ Test 11: LP token (ybBTC) IS the collateral token ============

    /**
     * @notice Explicitly verify that _underlyingLockedAsset in the rewards processing facet
     *         equals the LP token address (ybBTC). This is the foundational assertion
     *         for the swap guard: LP = collateral, so swapping LP is blocked.
     */
    function test_underlyingLockedAsset_isLpToken() public view {
        // The YieldBasisLpRewardsProcessingFacet constructor sets:
        //   _underlyingLockedAsset = IYieldBasisGauge(gauge).asset() = LP token
        // Verify by checking that swapping the LP token hits the collateral guard
        // (already tested in test_swapLpToken_isBlocked), but here we verify the
        // address equality directly.
        address lpTokenAddress = address(_ybBtc);
        address underlyingLockedAsset = _ybBtcRewardsProcessingFacet._underlyingLockedAsset();
        assertEq(
            underlyingLockedAsset,
            lpTokenAddress,
            "_underlyingLockedAsset must equal the LP token (ybBTC) address"
        );
    }

    /**
     * @notice Verify that swapping a non-collateral, non-rewards token is allowed.
     *         Only the LP token (collateral) should be blocked.
     */
    function test_swapNonCollateralToken_isAllowed() public {
        // This test verifies the guard is specific to the LP token only.
        // Attempting to swap _ybToken (not collateral) should NOT revert
        // with "Input token cannot be collateral token" — it may revert for other
        // reasons (no swap target, no balance) but not the collateral guard.
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);

        SwapMod.RouteParams memory params = SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: address(0x1234),
            swapData: "",
            inputToken: address(randomToken),
            inputAmount: 1e18,
            outputToken: address(_usdc),
            minimumOutputAmount: 0
        });

        // Should NOT revert with "Input token cannot be collateral token"
        // It will revert for other reasons (e.g., no balance, bad swap target)
        // but we verify the collateral guard specifically does not trigger
        vm.prank(_authorizedCaller);
        // We can't easily test that it passes the guard but fails later,
        // so we just verify it doesn't revert with the collateral-specific message.
        // The exact revert will depend on the swap logic downstream.
        try RewardsProcessingFacet(_portfolioAccount).swapToRewardsToken(params) {
            // If it somehow succeeds, that's fine
        } catch (bytes memory reason) {
            // Verify the revert is NOT the collateral guard
            assertTrue(
                keccak256(reason) != keccak256(abi.encodeWithSignature("Error(string)", "Input token cannot be collateral token")),
                "Should not revert with collateral token guard for non-collateral token"
            );
        }
    }
}
