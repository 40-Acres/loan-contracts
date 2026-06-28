// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * DynamicERC4626RewardsProcessingFacet (+ the Dynamic ERC4626 facet family)
 *
 * What is under test
 * ------------------
 * The live-debt-read variant of the ERC4626 collateral system:
 *   DynamicERC4626CollateralFacet / DynamicERC4626CollateralManager
 *   DynamicERC4626LendingFacet
 *   DynamicERC4626ClaimingFacet
 *   DynamicERC4626RewardsProcessingFacet
 *
 * Unlike the cached-debt ERC4626 family, debt is NEVER cached. Every read goes
 * live to the lending pool: getTotalDebt() -> lendingPool.getDebtBalance(this),
 * getEffectiveTotalDebt() -> getEffectiveDebtBalance(this). Headroom/utilization
 * use effective debt; solvency reverts use raw debt. The rewards facet rebinds
 * _getTotalDebt / _getLoanUtilization / _decreaseTotalDebt to the Dynamic
 * manager so it reads the live pool balance, not a (zero) cached slot.
 *
 * Like-to-like harness (mirrors ERC4626RewardsProcessingFacet.t.sol exactly,
 * but deploys the DYNAMIC facets):
 *   MockERC20 (6dp) is BOTH the underlying AND the lending asset.
 *   MockERC4626  = collateral vault (collateralVault).
 *   DynamicFeesVault = lending vault (lendingVault). It implements both
 *     getDebtBalance AND getEffectiveDebtBalance, so it is the correct pool for
 *     the Dynamic family. Because lending asset == underlying, getRewardsToken()
 *     == underlying and no swaps are needed.
 *
 * Fee model (LoanConfig in setUp):
 *   treasuryFee   = 500 bps  (5%)
 *   lenderPremium = 2000 bps (20%, flat)
 *   zeroBalanceFee= 100 bps  (1%)
 * Treasury resolves to the LoanConfig owner (_owner). Account owner / default
 * rewards recipient is _user.
 *
 * Notes on the live-debt design as it affects assertions
 * -------------------------------------------------------
 * - DynamicFeesVault.getDebtBalance == getEffectiveDebtBalance absent active
 *   reward streaming on the borrower's own loan, so the effective<=raw invariant
 *   holds as equality in these tests. Documented in the invariant test.
 * - No time travel is required; we avoid backward vm.warp (via-ir checkpoint
 *   pitfall) and do not roll blocks.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";
import {DynamicERC4626CollateralFacet} from "../../../src/facets/account/erc4626/DynamicERC4626CollateralFacet.sol";
import {DynamicERC4626CollateralManager} from "../../../src/facets/account/erc4626/DynamicERC4626CollateralManager.sol";
import {DynamicERC4626LendingFacet} from "../../../src/facets/account/erc4626/DynamicERC4626LendingFacet.sol";
import {DynamicERC4626ClaimingFacet} from "../../../src/facets/account/erc4626/DynamicERC4626ClaimingFacet.sol";
import {DynamicERC4626RewardsProcessingFacet} from "../../../src/facets/account/erc4626/DynamicERC4626RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DeployDynamicERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployDynamicERC4626CollateralFacet.s.sol";
import {DeployDynamicERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployDynamicERC4626LendingFacet.s.sol";
import {DeployDynamicERC4626ClaimingFacet} from "../../../script/portfolio_account/facets/DeployDynamicERC4626ClaimingFacet.s.sol";
import {DeployDynamicERC4626RewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployDynamicERC4626RewardsProcessingFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployERC4626PortfolioFactoryConfig} from "../../../script/portfolio_account/DeployERC4626PortfolioFactoryConfig.s.sol";
import {ERC4626PortfolioFactoryConfig} from "../../../src/facets/account/erc4626/ERC4626PortfolioFactoryConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DynamicERC4626RewardsProcessingFacetTest is Test {
    DynamicERC4626CollateralFacet public _collateralFacet;
    DynamicERC4626LendingFacet public _lendingFacet;
    DynamicERC4626ClaimingFacet public _claimingFacet;
    DynamicERC4626RewardsProcessingFacet public _rewardsFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    SwapConfig public _swapConfig;

    MockERC20 public _underlyingAsset;
    MockERC4626 public _mockVault;

    address public _loanContract;
    address public _lendingVault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 constant INITIAL_DEPOSIT = 1000e6;
    uint256 constant SETUP_FUND_BLOCK = 100;
    uint256 constant BORROW_AMOUNT = 30e6;
    uint256 constant REWARDS_AMOUNT = 10e6;

    uint256 constant TREASURY_FEE_BPS = 500;
    uint256 constant LENDER_PREMIUM_BPS = 2000;
    uint256 constant ZERO_BALANCE_FEE_BPS = 100;

    event ZeroBalanceFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event LenderPremiumPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ProtocolFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event Paid(uint256 amount, address indexed owner);

    function setUp() public virtual {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory factory, FacetRegistry registry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("dynamic-erc4626-rewards-test")))
        );
        _portfolioFactory = factory;
        _facetRegistry = registry;

        DeployPortfolioFactoryConfig configDeployer = new DeployERC4626PortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy(address(_portfolioFactory), _owner);

        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        _mockVault = new MockERC4626(address(_underlyingAsset), "Mock Collateral Vault", "mCVAULT", 6);

        _setupLendingInfrastructure();

        DeployDynamicERC4626CollateralFacet collatDeployer = new DeployDynamicERC4626CollateralFacet();
        _collateralFacet = collatDeployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployDynamicERC4626LendingFacet lendingDeployer = new DeployDynamicERC4626LendingFacet();
        _lendingFacet = lendingDeployer.deploy(address(_portfolioFactory), address(_underlyingAsset), address(_mockVault));

        DeployDynamicERC4626ClaimingFacet claimingDeployer = new DeployDynamicERC4626ClaimingFacet();
        _claimingFacet = claimingDeployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployDynamicERC4626RewardsProcessingFacet rewardsDeployer = new DeployDynamicERC4626RewardsProcessingFacet();
        _rewardsFacet = rewardsDeployer.deploy(
            address(_portfolioFactory),
            address(_swapConfig),
            address(_mockVault),       // collateral vault == lending facet's vault
            _lendingVault,             // lending / reinvest vault
            address(_underlyingAsset)  // default token
        );

        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000);
        _loanConfig.setLtv(7000);
        _loanConfig.setLenderPremium(LENDER_PREMIUM_BPS);
        _loanConfig.setTreasuryFee(TREASURY_FEE_BPS);
        _loanConfig.setZeroBalanceFee(ZERO_BALANCE_FEE_BPS);
        _portfolioFactoryConfig.setLoanContract(_loanContract);
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));
        ERC4626PortfolioFactoryConfig(address(_portfolioFactoryConfig)).setCollateralVault(address(_mockVault));

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Fund vault, then settle one block so it counts toward borrow capacity.
        vm.roll(SETUP_FUND_BLOCK);
        _underlyingAsset.mint(address(this), 10_000e6);
        _underlyingAsset.approve(_lendingVault, 10_000e6);
        DynamicFeesVault(payable(_lendingVault)).deposit(10_000e6, address(this));
        vm.roll(SETUP_FUND_BLOCK + 1);
    }

    function _setupLendingInfrastructure() internal {
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(_underlyingAsset),
            "Dynamic ERC4626 Lending Vault",
            "dlVAULT",
            address(_portfolioFactory),
            address(this),
            uint256(0)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        DynamicFeesVault dynamicVault = DynamicFeesVault(address(vaultProxy));
        _loanContract = address(dynamicVault);
        _lendingVault = address(dynamicVault);
        dynamicVault.transferOwnership(_owner);
        dynamicVault.acceptOwnership();
    }

    // ------------------------ helpers ------------------------

    function _stageShares(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(_user);
        _underlyingAsset.mint(_user, assets);
        _underlyingAsset.approve(address(_mockVault), assets);
        shares = _mockVault.deposit(assets, _user);
        _mockVault.transfer(_portfolioAccount, shares);
        vm.stopPrank();
    }

    function _addCollateral(uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(DynamicERC4626CollateralFacet.addCollateral.selector, shares);
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();
    }

    function _borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(DynamicERC4626LendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();
    }

    /// @dev Establish `borrowAmount` of Dynamic ERC4626 debt on the portfolio account.
    function _establishDebt(uint256 borrowAmount) internal {
        uint256 shares = _stageShares(INITIAL_DEPOSIT);
        _addCollateral(shares);
        _borrowViaMulticall(borrowAmount);
    }

    function _fundRewards(uint256 amount) internal {
        _underlyingAsset.mint(_portfolioAccount, amount);
    }

    function _processRewards(uint256 amount) internal {
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(_authorizedCaller);
        DynamicERC4626RewardsProcessingFacet(_portfolioAccount).processRewards(0, amount, noSwap, 0);
    }

    function _treasury() internal view returns (address) {
        return _loanConfig.getTreasury();
    }

    // ============================================================
    // 1. Pays down Dynamic ERC4626 debt (reads live pool debt)
    // ============================================================

    /// @notice With real live-read debt and rewards < debt, processRewards must
    ///         charge protocol fee + lender premium, then route the post-fee
    ///         remainder to debt paydown. If the facet read the wrong (base) slot
    ///         it would see zero debt and skip paydown.
    function test_processRewards_paysDownDebt() public {
        _establishDebt(BORROW_AMOUNT);

        uint256 debtBefore = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "precondition: debt == 30e6");

        _fundRewards(REWARDS_AMOUNT);

        address treasury = _treasury();
        uint256 treasuryBefore = _underlyingAsset.balanceOf(treasury);

        uint256 expectedProtocolFee = (REWARDS_AMOUNT * TREASURY_FEE_BPS) / 10000;     // 0.5e6
        uint256 expectedLenderPremium = (REWARDS_AMOUNT * LENDER_PREMIUM_BPS) / 10000; // 2e6
        uint256 expectedToDebt = REWARDS_AMOUNT - expectedProtocolFee - expectedLenderPremium; // 7.5e6

        _processRewards(REWARDS_AMOUNT);

        uint256 debtAfter = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();

        assertLt(debtAfter, debtBefore, "debt must strictly decrease");
        assertApproxEqAbs(debtBefore - debtAfter, expectedToDebt, 10, "debt reduced ~= post-fee amount");
        assertEq(
            _underlyingAsset.balanceOf(treasury) - treasuryBefore,
            expectedProtocolFee,
            "treasury received protocol fee"
        );
    }

    // ============================================================
    // 2. Uses the Dynamic manager debt read (hasDebt branch)
    // ============================================================

    /// @notice getRewardsToken() must be the underlying/lending asset, and with
    ///         real live-read debt present processRewards must take the hasDebt
    ///         branch -- proven by ProtocolFeePaid + LenderPremiumPaid (only the
    ///         hasDebt path emits those), NOT ZeroBalanceFeePaid.
    function test_processRewards_usesDynamicManagerDebt() public {
        _establishDebt(BORROW_AMOUNT);
        _fundRewards(REWARDS_AMOUNT);

        assertEq(
            DynamicERC4626RewardsProcessingFacet(_portfolioAccount).getRewardsToken(),
            address(_underlyingAsset),
            "rewards token must be the lending asset"
        );

        uint256 expectedProtocolFee = (REWARDS_AMOUNT * TREASURY_FEE_BPS) / 10000;
        uint256 expectedLenderPremium = (REWARDS_AMOUNT * LENDER_PREMIUM_BPS) / 10000;

        vm.expectEmit(false, true, false, true, _portfolioAccount);
        emit ProtocolFeePaid(0, 0, expectedProtocolFee, _user, address(_underlyingAsset));
        vm.expectEmit(false, true, false, true, _portfolioAccount);
        emit LenderPremiumPaid(0, 0, expectedLenderPremium, _user, address(_underlyingAsset));

        _processRewards(REWARDS_AMOUNT);
    }

    // ============================================================
    // 3. Excess over debt -> deposited into lending vault for owner
    // ============================================================

    /// @notice When rewards greatly exceed debt, debt must clear to zero and the
    ///         leftover (post-fee, post-debt) must be deposited into the lending
    ///         vault crediting the account owner. Nothing should be stranded.
    function test_processRewards_excessOverDebt_depositsToLendingVault() public {
        _establishDebt(BORROW_AMOUNT); // 30e6 debt

        uint256 rewards = 100e6; // >> debt
        _fundRewards(rewards);

        uint256 ownerSharesBefore = DynamicFeesVault(payable(_lendingVault)).balanceOf(_user);

        _processRewards(rewards);

        assertEq(DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "debt cleared to 0");

        uint256 ownerSharesAfter = DynamicFeesVault(payable(_lendingVault)).balanceOf(_user);
        assertGt(ownerSharesAfter, ownerSharesBefore, "owner received lending-vault shares from excess");

        assertEq(_underlyingAsset.balanceOf(_portfolioAccount), 0, "no rewards token stranded on account");
    }

    // ============================================================
    // 4. IncreaseCollateral option is a safe no-op
    // ============================================================

    /// @notice IncreaseCollateral is unsupported for ERC4626 collateral and is a
    ///         no-op in the Dynamic facet (_increaseCollateral returns 0, and
    ///         _routeForDistributionEntry returns an empty route). A misconfigured
    ///         active-balance entry using IncreaseCollateral must NOT swap or
    ///         strand funds; the option amount must flow to debt paydown,
    ///         behaving identically to a run with no distribution configured.
    function test_increaseCollateralOption_isSafeNoOp() public {
        // --- Baseline: no active-balance distribution ---
        _establishDebt(BORROW_AMOUNT);
        _fundRewards(REWARDS_AMOUNT);
        _processRewards(REWARDS_AMOUNT);
        uint256 baselineDebt = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 baselineStranded = _underlyingAsset.balanceOf(_portfolioAccount);

        // --- Variant: configure IncreaseCollateral active-balance entry, same inputs ---
        setUp(); // fresh state
        _establishDebt(BORROW_AMOUNT);

        UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 20,
            outputToken: address(0),
            target: address(0)
        });
        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(RewardsConfigFacet.setActiveBalanceDistribution.selector, entry);
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();

        assertTrue(_activeBalanceConfigured(), "active-balance distribution should be configured");

        _fundRewards(REWARDS_AMOUNT);
        _processRewards(REWARDS_AMOUNT);

        uint256 variantDebt = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 variantStranded = _underlyingAsset.balanceOf(_portfolioAccount);

        assertEq(variantDebt, baselineDebt, "IncreaseCollateral entry must not change debt outcome");
        assertEq(variantStranded, baselineStranded, "IncreaseCollateral entry must not strand funds");
        assertEq(variantStranded, 0, "no funds stranded");
    }

    function _activeBalanceConfigured() internal view returns (bool) {
        UserRewardsConfig.DistributionEntry memory e =
            RewardsConfigFacet(_portfolioAccount).getActiveBalanceDistribution();
        return e.percentage == 20 && e.option == UserRewardsConfig.RewardsOption.IncreaseCollateral;
    }

    // ============================================================
    // 5. Zero debt -> zero-balance branch
    // ============================================================

    /// @notice With no live-read debt, processRewards must take the zero-balance
    ///         branch: charge the zero-balance fee to treasury and forward the
    ///         remainder to the recipient (owner).
    function test_zeroDebt_takesZeroBalanceBranch() public {
        assertEq(DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "precondition: no debt");

        _fundRewards(REWARDS_AMOUNT);

        address treasury = _treasury();
        uint256 treasuryBefore = _underlyingAsset.balanceOf(treasury);
        uint256 ownerBefore = _underlyingAsset.balanceOf(_user);

        uint256 expectedZBF = (REWARDS_AMOUNT * ZERO_BALANCE_FEE_BPS) / 10000; // 0.1e6
        uint256 expectedToRecipient = REWARDS_AMOUNT - expectedZBF;            // 9.9e6

        vm.expectEmit(false, true, false, true, _portfolioAccount);
        emit ZeroBalanceFeePaid(0, 0, expectedZBF, _user, address(_underlyingAsset));

        _processRewards(REWARDS_AMOUNT);

        assertEq(
            _underlyingAsset.balanceOf(treasury) - treasuryBefore,
            expectedZBF,
            "treasury received zero-balance fee"
        );
        assertEq(
            _underlyingAsset.balanceOf(_user) - ownerBefore,
            expectedToRecipient,
            "recipient (owner) received remainder after ZBF"
        );
        assertEq(_underlyingAsset.balanceOf(_portfolioAccount), 0, "no rewards token stranded");
    }

    // ============================================================
    // 6. Invariant: effective debt <= raw debt
    // ============================================================

    /// @notice Core invariant of the live-debt-read design: getEffectiveTotalDebt
    ///         (used for headroom/utilization) must never exceed getTotalDebt
    ///         (raw, used for solvency reverts). In this harness the DynamicFeesVault
    ///         returns equal values absent active borrower reward streaming, so
    ///         this asserts as equality -- which still satisfies effective <= raw.
    ///         The library has no setter to push effective above raw, so equality
    ///         here documents the lower-bound case while the <= assertion guards
    ///         the general property.
    function test_invariant_effectiveDebtLeqRawDebt() public {
        _establishDebt(BORROW_AMOUNT);

        // Raw debt as the facet exposes it (manager reads it live from the pool
        // for the account). This is the value used for solvency reverts.
        uint256 rawDebtViaFacet = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(rawDebtViaFacet, BORROW_AMOUNT, "raw debt == borrowed amount");

        // Read raw and effective straight from the pool for the SAME borrower the
        // manager queries (the portfolio account). These are exactly the calls the
        // manager makes internally, so this validates the invariant at the source.
        uint256 rawFromPool = ILendingPool(_lendingVault).getDebtBalance(_portfolioAccount);
        uint256 effectiveFromPool = ILendingPool(_lendingVault).getEffectiveDebtBalance(_portfolioAccount);

        assertEq(rawFromPool, rawDebtViaFacet, "facet raw debt == pool getDebtBalance(account)");
        assertLe(effectiveFromPool, rawFromPool, "invariant: effective debt <= raw debt");
        // Documented: the DynamicFeesVault returns equal values absent active
        // borrower reward streaming, so this asserts as equality here -- still
        // satisfying effective <= raw.
        assertEq(effectiveFromPool, rawFromPool, "no streaming -> effective == raw here");
    }

    // ============================================================
    // 7. Overpay via pay() clamps to live debt and returns the unspent overage
    // ============================================================

    /// @notice DynamicERC4626LendingFacet.pay caps to live debt before pulling
    ///         funds and must return requestedAmount - actuallyPaid. Mirrors the
    ///         regular ERC4626LendingFacetPay overpay test against the Dynamic facet.
    function test_borrow_then_payViaPay_clampsToLiveDebt() public {
        _establishDebt(BORROW_AMOUNT);

        uint256 debtBefore = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "precondition: debt == 30e6");

        uint256 overpay = 100e6;
        address payer = address(0xBADADD);
        _underlyingAsset.mint(payer, overpay);
        vm.prank(payer);
        _underlyingAsset.approve(_portfolioAccount, overpay);

        uint256 payerBalBefore = _underlyingAsset.balanceOf(payer);

        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit Paid(BORROW_AMOUNT, payer);

        vm.prank(payer);
        uint256 returnedExcess = DynamicERC4626LendingFacet(_portfolioAccount).pay(overpay);

        assertEq(returnedExcess, overpay - BORROW_AMOUNT, "pay() returns requestedAmount - actuallyPaid (70e6)");

        uint256 payerBalAfter = _underlyingAsset.balanceOf(payer);
        assertEq(payerBalBefore - payerBalAfter, BORROW_AMOUNT, "payer net out == actual debt paid (30e6)");

        assertEq(DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "debt -> 0");
    }

    // ============================================================
    // 8. addCollateral with more shares than held reverts
    // ============================================================

    /// @notice addCollateral must revert with InsufficientShareBalance when the
    ///         account does not actually hold the requested shares. Guards against
    ///         crediting fictitious collateral / borrow capacity.
    function test_addCollateral_exceedingBalance_reverts() public {
        // Stage 1000e6 of shares onto the account.
        uint256 shares = _stageShares(INITIAL_DEPOSIT);
        uint256 actualBalance = _mockVault.balanceOf(_portfolioAccount);
        assertEq(actualBalance, shares, "account holds staged shares");

        uint256 tooMany = shares + 1;

        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(DynamicERC4626CollateralFacet.addCollateral.selector, tooMany);
        // Multicall bubbles the manager revert; assert the specific selector + args.
        vm.expectRevert(
            abi.encodeWithSelector(
                DynamicERC4626CollateralManager.InsufficientShareBalance.selector,
                tooMany,
                actualBalance
            )
        );
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();
    }

    // ============================================================
    // 9. End-to-end: add collateral, borrow, accrue yield, claim
    // ============================================================

    /// @notice Full path on the Dynamic family: deposit collateral, borrow, let
    ///         the MockERC4626 appreciate (donate underlying), claim the yield via
    ///         DynamicERC4626ClaimingFacet. Claimed assets land in the account and
    ///         debt remains serviceable (collateral still covers it).
    function test_borrowAndClaimYield_endToEnd() public {
        uint256 shares = _stageShares(INITIAL_DEPOSIT);
        _addCollateral(shares);
        _borrowViaMulticall(BORROW_AMOUNT);

        assertEq(DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), BORROW_AMOUNT, "debt established");

        // Appreciate share price: donate underlying into the collateral vault
        // without minting shares (same technique as ERC4626ClaimingFacet tests).
        uint256 yield = 100e6;
        _underlyingAsset.mint(_owner, yield);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), yield);
        _mockVault.simulateYield(yield);
        vm.stopPrank();

        (uint256 yieldAssets, uint256 yieldShares) =
            DynamicERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertGt(yieldAssets, 0, "yield is available");
        assertGt(yieldShares, 0, "yield shares available");

        uint256 accountAssetsBefore = _underlyingAsset.balanceOf(_portfolioAccount);

        vm.prank(_authorizedCaller);
        uint256 claimed = DynamicERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);

        assertGt(claimed, 0, "claimed positive yield");
        assertEq(
            _underlyingAsset.balanceOf(_portfolioAccount),
            accountAssetsBefore + claimed,
            "claimed assets land in the account"
        );

        // Debt unchanged by claiming (claim only touches collateral shares),
        // and still covered: enforceCollateralRequirements must not revert.
        assertEq(DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), BORROW_AMOUNT, "debt unchanged by claim");
        assertTrue(
            DynamicERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements(),
            "collateral still covers debt after yield claim"
        );

        // The principal-worth of collateral must remain (claim only harvests yield).
        (, uint256 depositedAssetValue, uint256 currentAssetValue) =
            _claimCollateralView();
        assertGe(currentAssetValue, depositedAssetValue, "principal collateral value preserved after harvest");
    }

    function _claimCollateralView() internal view returns (uint256 sh, uint256 dep, uint256 cur) {
        (, sh, dep, cur) = DynamicERC4626ClaimingFacet(_portfolioAccount).getDepositInfo();
    }

    // ============================================================
    // 10. End-to-end: claim vault yield THEN process the claimed balance
    // ============================================================

    /// @notice The full real pipeline that proves claimed yield is no longer
    ///         stranded (the original audit finding), exercised through the real
    ///         claim path rather than a simulated/minted balance:
    ///           addCollateral -> borrow -> appreciate collateral vault ->
    ///           claimVaultYield (leaves underlying on the account, like-to-like
    ///           with the rewards token so NO swap is needed) -> processRewards
    ///           feeding exactly the just-claimed balance.
    ///         Asserts the claimed yield actually pays down live debt (strict
    ///         decrease from the post-borrow level) and the protocol fee reaches
    ///         the treasury -- i.e. the claimed assets flow all the way through
    ///         the rewards pipeline instead of sitting idle on the account.
    function test_claimThenProcessRewards_endToEnd() public {
        // 1. Establish debt.
        uint256 shares = _stageShares(INITIAL_DEPOSIT);
        _addCollateral(shares);
        _borrowViaMulticall(BORROW_AMOUNT);

        uint256 debtAfterBorrow = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfterBorrow, BORROW_AMOUNT, "precondition: debt == 30e6 after borrow");

        // 2. Appreciate the collateral vault so there is harvestable yield.
        uint256 yield = 100e6;
        _underlyingAsset.mint(_owner, yield);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), yield);
        _mockVault.simulateYield(yield);
        vm.stopPrank();

        // 3. Claim the yield. Claimed underlying lands directly on the account.
        uint256 accountBalBeforeClaim = _underlyingAsset.balanceOf(_portfolioAccount);
        vm.prank(_authorizedCaller);
        uint256 claimed = DynamicERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);
        assertGt(claimed, 0, "claimed positive yield");

        // 4. Read the just-claimed balance. getRewardsToken() == underlying
        //    (like-to-like), so this is the amount to feed processRewards.
        assertEq(
            DynamicERC4626RewardsProcessingFacet(_portfolioAccount).getRewardsToken(),
            address(_underlyingAsset),
            "rewards token must be the lending asset (no swap needed)"
        );
        uint256 claimedBalance = _underlyingAsset.balanceOf(_portfolioAccount);
        assertEq(claimedBalance, accountBalBeforeClaim + claimed, "claimed balance present before processing");
        assertGt(claimedBalance, 0, "claimed balance available to process");

        address treasury = _treasury();
        uint256 treasuryBefore = _underlyingAsset.balanceOf(treasury);

        // Claimed amount is well below debt (yield ~100e6 of value on 1000e6
        // principal redeems to a small underlying amount << 30e6 debt), so the
        // hasDebt branch routes the post-fee remainder to debt paydown.
        uint256 expectedProtocolFee = (claimedBalance * TREASURY_FEE_BPS) / 10000;

        // 5. Process the claimed balance through the real rewards pipeline.
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(_authorizedCaller);
        DynamicERC4626RewardsProcessingFacet(_portfolioAccount).processRewards(0, claimedBalance, noSwap, 0);

        // 6. Debt strictly decreased -> claimed yield reached debt paydown.
        uint256 debtAfterProcess = DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfterProcess, debtAfterBorrow, "claimed yield paid down debt through full pipeline");

        // Protocol fee reached the treasury (small split; approx for rounding).
        assertApproxEqAbs(
            _underlyingAsset.balanceOf(treasury) - treasuryBefore,
            expectedProtocolFee,
            2,
            "treasury received protocol fee from claimed-yield processing"
        );

        // Nothing stranded: the claimed balance was fully routed.
        assertEq(_underlyingAsset.balanceOf(_portfolioAccount), 0, "no claimed rewards stranded after processing");
    }
}
