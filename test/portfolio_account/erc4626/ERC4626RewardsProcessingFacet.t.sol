// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * ERC4626RewardsProcessingFacet
 *
 * What is under test
 * ------------------
 * ERC4626 portfolio accounts had no rewards-processing facet, so yield left in
 * the account (e.g. by ERC4626ClaimingFacet.claimVaultYield) was stranded. The
 * base RewardsProcessingFacet cannot be reused: it reads the base
 * CollateralManager storage slot, not ERC4626CollateralManager, so it sees zero
 * debt and takes the wrong (zero-balance) branch.
 *
 * ERC4626RewardsProcessingFacet rebinds the debt/utilization hooks to
 * ERC4626CollateralManager. It passes the lending vault as the base `_vault`
 * (so getRewardsToken() == lending asset and excess reinvests into the lending
 * vault) and stores the collateral vault separately.
 *
 * Like-to-like harness
 * --------------------
 * MockERC20 (6dp) is BOTH the underlying AND the lending asset. MockERC4626 is
 * the collateral vault; DynamicFeesVault is the lending vault. Because the
 * lending vault asset == underlying, getRewardsToken() == underlying and NO
 * swaps are needed (empty SwapMod.RouteParams[4]).
 *
 * Fee model in this harness (LoanConfig set in setUp):
 *   treasuryFee   = 500 bps  (5%)
 *   lenderPremium = 2000 bps (20%, flat -- no curve set)
 *   zeroBalanceFee= 100 bps  (1%)
 * Treasury resolves to the LoanConfig owner (_owner) since setTreasury is never
 * called. Account owner / default rewards recipient is _user.
 *
 * Setup mirrors ERC4626LendingFacetPay.t.sol exactly, plus the new rewards
 * facet wired via DeployERC4626RewardsProcessingFacet.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";
import {ERC4626ClaimingFacet} from "../../../src/facets/account/erc4626/ERC4626ClaimingFacet.sol";
import {ERC4626RewardsProcessingFacet} from "../../../src/facets/account/erc4626/ERC4626RewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";
import {DeployERC4626ClaimingFacet} from "../../../script/portfolio_account/facets/DeployERC4626ClaimingFacet.s.sol";
import {DeployERC4626RewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployERC4626RewardsProcessingFacet.s.sol";
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
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC4626RewardsProcessingFacetTest is Test {
    ERC4626CollateralFacet public _collateralFacet;
    ERC4626LendingFacet public _lendingFacet;
    ERC4626ClaimingFacet public _claimingFacet;
    ERC4626RewardsProcessingFacet public _rewardsFacet;
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
    uint256 constant BORROW_AMOUNT = 30e6;
    uint256 constant REWARDS_AMOUNT = 10e6;

    // Fee bps configured in setUp
    uint256 constant TREASURY_FEE_BPS = 500;
    uint256 constant LENDER_PREMIUM_BPS = 2000;
    uint256 constant ZERO_BALANCE_FEE_BPS = 100;

    event ZeroBalanceFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event LenderPremiumPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ProtocolFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);

    function setUp() public virtual {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory factory, FacetRegistry registry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-rewards-test")))
        );
        _portfolioFactory = factory;
        _facetRegistry = registry;

        DeployPortfolioFactoryConfig configDeployer = new DeployERC4626PortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy(address(_portfolioFactory), _owner);

        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        _mockVault = new MockERC4626(address(_underlyingAsset), "Mock Collateral Vault", "mCVAULT", 6);

        _setupLendingInfrastructure();

        DeployERC4626CollateralFacet collatDeployer = new DeployERC4626CollateralFacet();
        _collateralFacet = collatDeployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        _lendingFacet = lendingDeployer.deploy(address(_portfolioFactory), address(_underlyingAsset), address(_mockVault));

        DeployERC4626ClaimingFacet claimingDeployer = new DeployERC4626ClaimingFacet();
        _claimingFacet = claimingDeployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployERC4626RewardsProcessingFacet rewardsDeployer = new DeployERC4626RewardsProcessingFacet();
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

        // Fund lending vault so there's borrow capacity.
        _underlyingAsset.mint(address(this), 10_000e6);
        _underlyingAsset.approve(_lendingVault, 10_000e6);
        DynamicFeesVault(payable(_lendingVault)).deposit(10_000e6, address(this));
    }

    function _setupLendingInfrastructure() internal {
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(_underlyingAsset),
            "ERC4626 Lending Vault",
            "lVAULT",
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
        data[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();
    }

    function _borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();
    }

    /// @dev Establish `borrowAmount` of ERC4626 debt on the portfolio account.
    function _establishDebt(uint256 borrowAmount) internal {
        uint256 shares = _stageShares(INITIAL_DEPOSIT);
        _addCollateral(shares);
        _borrowViaMulticall(borrowAmount);
    }

    /// @dev Fund the portfolio account with `amount` of the rewards token (underlying).
    function _fundRewards(uint256 amount) internal {
        _underlyingAsset.mint(_portfolioAccount, amount);
    }

    function _processRewards(uint256 amount) internal {
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(_authorizedCaller);
        ERC4626RewardsProcessingFacet(_portfolioAccount).processRewards(0, amount, noSwap, 0);
    }

    function _treasury() internal view returns (address) {
        return _loanConfig.getTreasury();
    }

    // ============================================================
    // 1. Pays down ERC4626 debt
    // ============================================================

    /// @notice With real ERC4626 debt and rewards < debt, processRewards must
    ///         charge the protocol fee + lender premium, then route the post-fee
    ///         remainder to ERC4626 debt paydown. Debt must strictly decrease and
    ///         the treasury must receive the protocol fee. If the facet read the
    ///         wrong (base) storage slot it would see zero debt and skip paydown.
    function test_processRewards_paysDownERC4626Debt() public {
        _establishDebt(BORROW_AMOUNT);

        uint256 debtBefore = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "precondition: debt == 30e6");

        _fundRewards(REWARDS_AMOUNT);

        address treasury = _treasury();
        uint256 treasuryBefore = _underlyingAsset.balanceOf(treasury);

        uint256 expectedProtocolFee = (REWARDS_AMOUNT * TREASURY_FEE_BPS) / 10000;   // 0.5e6
        uint256 expectedLenderPremium = (REWARDS_AMOUNT * LENDER_PREMIUM_BPS) / 10000; // 2e6
        uint256 expectedToDebt = REWARDS_AMOUNT - expectedProtocolFee - expectedLenderPremium; // 7.5e6

        _processRewards(REWARDS_AMOUNT);

        uint256 debtAfter = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();

        // Core: debt strictly decreased -> took the hasDebt branch, not zero-balance.
        assertLt(debtAfter, debtBefore, "debt must strictly decrease");

        // Debt reduced by approximately the post-fee amount routed to paydown.
        // Tolerance covers any vault-side settlement rounding during payFromPortfolio.
        assertApproxEqAbs(debtBefore - debtAfter, expectedToDebt, 10, "debt reduced ~= post-fee amount");

        // Treasury received exactly the protocol fee.
        assertEq(
            _underlyingAsset.balanceOf(treasury) - treasuryBefore,
            expectedProtocolFee,
            "treasury received protocol fee"
        );
    }

    // ============================================================
    // 2. Uses ERC4626 utilization / hasDebt branch (correct storage slot)
    // ============================================================

    /// @notice The core "correct storage slot" assertion. getRewardsToken() must
    ///         be the underlying/lending asset, and with real ERC4626 debt present
    ///         processRewards must take the hasDebt branch -- proven by emission of
    ///         LenderPremiumPaid (only emitted on the hasDebt path) and ProtocolFeePaid.
    function test_processRewards_usesERC4626Utilization_notBaseSlot() public {
        _establishDebt(BORROW_AMOUNT);
        _fundRewards(REWARDS_AMOUNT);

        // Rewards token is the lending vault asset == underlying (like-to-like).
        assertEq(
            ERC4626RewardsProcessingFacet(_portfolioAccount).getRewardsToken(),
            address(_underlyingAsset),
            "rewards token must be the lending asset"
        );

        // hasDebt branch emits ProtocolFeePaid AND LenderPremiumPaid.
        // Zero-balance branch would emit ZeroBalanceFeePaid instead and never these two.
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
    ///         vault crediting the account owner (per inherited _depositRemainingToVault,
    ///         which deposits `_vault` -> recipient == owner). The owner should
    ///         receive lending-vault shares.
    function test_processRewards_excessOverDebt_depositsToLendingVault() public {
        _establishDebt(BORROW_AMOUNT); // 30e6 debt

        uint256 rewards = 100e6; // >> debt
        _fundRewards(rewards);

        uint256 ownerSharesBefore = DynamicFeesVault(payable(_lendingVault)).balanceOf(_user);

        _processRewards(rewards);

        // Debt fully cleared.
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "debt cleared to 0");

        // Leftover reinvested into the lending vault for the owner.
        uint256 ownerSharesAfter = DynamicFeesVault(payable(_lendingVault)).balanceOf(_user);
        assertGt(ownerSharesAfter, ownerSharesBefore, "owner received lending-vault shares from excess");

        // No rewards token should be stranded on the account (all fee/debt/reinvest routed).
        assertEq(_underlyingAsset.balanceOf(_portfolioAccount), 0, "no rewards token stranded on account");
    }

    // ============================================================
    // 4. IncreaseCollateral option is a safe no-op
    // ============================================================

    /// @notice IncreaseCollateral is unsupported for ERC4626 collateral. A
    ///         misconfigured active-balance entry using IncreaseCollateral must
    ///         NOT swap or strand funds; the option amount must stay in `remaining`
    ///         and flow to debt paydown -- behaving as if the option were absent.
    ///
    ///         We compare against a baseline run with NO active-balance distribution
    ///         to prove the IncreaseCollateral entry changes nothing about the debt
    ///         outcome (no funds diverted/stranded).
    function test_increaseCollateralOption_isSafeNoOp() public {
        // --- Baseline: no active-balance distribution ---
        _establishDebt(BORROW_AMOUNT);
        _fundRewards(REWARDS_AMOUNT);
        _processRewards(REWARDS_AMOUNT);
        uint256 baselineDebt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 baselineStranded = _underlyingAsset.balanceOf(_portfolioAccount);

        // --- Variant: configure IncreaseCollateral active-balance entry, same inputs ---
        setUp(); // fresh state
        _establishDebt(BORROW_AMOUNT);

        // Set an active-balance distribution with IncreaseCollateral (20%).
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

        // Confirm the entry is set.
        assertTrue(
            _activeBalanceConfigured(),
            "active-balance distribution should be configured"
        );

        _fundRewards(REWARDS_AMOUNT);
        _processRewards(REWARDS_AMOUNT);

        uint256 variantDebt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 variantStranded = _underlyingAsset.balanceOf(_portfolioAccount);

        // The IncreaseCollateral entry must be a no-op: same debt outcome as baseline,
        // and nothing stranded on the account / no collateral-asset placeholder swap.
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

    /// @notice With no ERC4626 debt, processRewards must take the zero-balance
    ///         branch: charge the zero-balance fee to treasury and forward the
    ///         remainder to the recipient (owner). Confirms the ERC4626 debt read
    ///         returning 0 still drives the no-debt path correctly.
    function test_zeroDebt_takesZeroBalanceBranch() public {
        // No debt established.
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "precondition: no debt");

        _fundRewards(REWARDS_AMOUNT);

        address treasury = _treasury();
        uint256 treasuryBefore = _underlyingAsset.balanceOf(treasury);
        uint256 ownerBefore = _underlyingAsset.balanceOf(_user); // recipient defaults to owner

        uint256 expectedZBF = (REWARDS_AMOUNT * ZERO_BALANCE_FEE_BPS) / 10000; // 0.1e6
        uint256 expectedToRecipient = REWARDS_AMOUNT - expectedZBF;            // 9.9e6

        // Zero-balance branch emits ZeroBalanceFeePaid.
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
    // 6. End-to-end: claim vault yield THEN process the claimed balance
    // ============================================================

    /// @notice The full real pipeline that proves claimed yield is no longer
    ///         stranded (the original audit finding), exercised through the real
    ///         claim path rather than a simulated/minted balance:
    ///           addCollateral -> borrow -> appreciate collateral vault ->
    ///           claimVaultYield (leaves underlying on the account, like-to-like
    ///           with the rewards token so NO swap is needed) -> processRewards
    ///           feeding exactly the just-claimed balance.
    ///         Asserts the claimed yield actually pays down debt (strict decrease
    ///         from the post-borrow level) and the protocol fee reaches the
    ///         treasury -- the claimed assets flow all the way through the rewards
    ///         pipeline instead of sitting idle on the account.
    function test_claimThenProcessRewards_endToEnd() public {
        // 1. Establish debt.
        uint256 shares = _stageShares(INITIAL_DEPOSIT);
        _addCollateral(shares);
        _borrowViaMulticall(BORROW_AMOUNT);

        uint256 debtAfterBorrow = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
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
        uint256 claimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);
        assertGt(claimed, 0, "claimed positive yield");

        // 4. Read the just-claimed balance. getRewardsToken() == underlying
        //    (like-to-like), so this is the amount to feed processRewards.
        assertEq(
            ERC4626RewardsProcessingFacet(_portfolioAccount).getRewardsToken(),
            address(_underlyingAsset),
            "rewards token must be the lending asset (no swap needed)"
        );
        uint256 claimedBalance = _underlyingAsset.balanceOf(_portfolioAccount);
        assertEq(claimedBalance, accountBalBeforeClaim + claimed, "claimed balance present before processing");
        assertGt(claimedBalance, 0, "claimed balance available to process");

        address treasury = _treasury();
        uint256 treasuryBefore = _underlyingAsset.balanceOf(treasury);

        // Claimed amount is well below debt, so the hasDebt branch routes the
        // post-fee remainder to debt paydown.
        uint256 expectedProtocolFee = (claimedBalance * TREASURY_FEE_BPS) / 10000;

        // 5. Process the claimed balance through the real rewards pipeline.
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(_authorizedCaller);
        ERC4626RewardsProcessingFacet(_portfolioAccount).processRewards(0, claimedBalance, noSwap, 0);

        // 6. Debt strictly decreased -> claimed yield reached debt paydown.
        uint256 debtAfterProcess = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
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

    // ============================================================
    // Companion documentation test: WHY the variant is needed.
    // The BASE RewardsProcessingFacet reads the base CollateralManager slot, not
    // ERC4626CollateralManager, so it sees zero debt on an ERC4626 account and
    // takes the zero-balance branch -- leaving ERC4626 debt UNCHANGED.
    //
    // Isolated on its OWN diamond/account (separate factory + manager) so its
    // processRewards selector does not collide with the variant's.
    // ============================================================

    PortfolioManager internal _pm2;
    PortfolioFactory internal _factory2;
    FacetRegistry internal _registry2;
    PortfolioFactoryConfig internal _pfc2;
    LoanConfig internal _lc2;
    SwapConfig internal _sc2;
    address internal _account2;
    address internal _lendingVault2;

    function _setupBaseFacetAccount() internal {
        vm.startPrank(_owner);

        _pm2 = new PortfolioManager(_owner);
        (PortfolioFactory f2, FacetRegistry r2) = _pm2.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-base-facet-doc")))
        );
        _factory2 = f2;
        _registry2 = r2;

        DeployPortfolioFactoryConfig cfg = new DeployERC4626PortfolioFactoryConfig();
        VotingConfig vc2;
        (_pfc2, vc2, _lc2, _sc2) = cfg.deploy(address(_factory2), _owner);

        // Reuse the same underlying + a fresh collateral vault for this diamond.
        MockERC4626 collatVault2 = new MockERC4626(address(_underlyingAsset), "Mock Collateral Vault 2", "mCVAULT2", 6);

        // Lending vault for factory 2.
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(_underlyingAsset),
            "ERC4626 Lending Vault 2",
            "lVAULT2",
            address(_factory2),
            address(this),
            uint256(0)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        DynamicFeesVault v2 = DynamicFeesVault(address(vaultProxy));
        _lendingVault2 = address(v2);
        v2.transferOwnership(_owner);
        v2.acceptOwnership();

        // ERC4626 collateral + lending facets (correct slot writers).
        DeployERC4626CollateralFacet cd = new DeployERC4626CollateralFacet();
        cd.deploy(address(_factory2), address(collatVault2));
        DeployERC4626LendingFacet ld = new DeployERC4626LendingFacet();
        ld.deploy(address(_factory2), address(_underlyingAsset), address(collatVault2));

        // Register the BASE RewardsProcessingFacet (WRONG slot reader) directly.
        RewardsProcessingFacet baseFacet = new RewardsProcessingFacet(
            address(_factory2),
            address(_sc2),
            address(_underlyingAsset), // underlyingLockedAsset
            _lendingVault2,            // vault
            address(_underlyingAsset)  // defaultToken
        );
        bytes4[] memory sels = new bytes4[](5);
        sels[0] = RewardsProcessingFacet.processRewards.selector;
        sels[1] = RewardsProcessingFacet.getRewardsToken.selector;
        sels[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        sels[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        sels[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registry2.registerFacet(address(baseFacet), sels, "RewardsProcessingFacet");

        _lc2.setRewardsRate(10000);
        _lc2.setMultiplier(7000);
        _lc2.setLtv(7000);
        _lc2.setLenderPremium(LENDER_PREMIUM_BPS);
        _lc2.setTreasuryFee(TREASURY_FEE_BPS);
        _lc2.setZeroBalanceFee(ZERO_BALANCE_FEE_BPS);
        _pfc2.setLoanContract(_lendingVault2);
        _pfc2.setLoanConfig(address(_lc2));
        _factory2.setPortfolioFactoryConfig(address(_pfc2));
        ERC4626PortfolioFactoryConfig(address(_pfc2)).setCollateralVault(address(collatVault2));

        _pm2.setAuthorizedCaller(_authorizedCaller, true);
        vm.stopPrank();

        _account2 = _factory2.createAccount(_user);

        // Fund lending vault 2.
        _underlyingAsset.mint(address(this), 10_000e6);
        _underlyingAsset.approve(_lendingVault2, 10_000e6);
        DynamicFeesVault(payable(_lendingVault2)).deposit(10_000e6, address(this));

        // Establish ERC4626 debt on account 2.
        vm.startPrank(_user);
        _underlyingAsset.mint(_user, INITIAL_DEPOSIT);
        _underlyingAsset.approve(address(collatVault2), INITIAL_DEPOSIT);
        uint256 shares = collatVault2.deposit(INITIAL_DEPOSIT, _user);
        collatVault2.transfer(_account2, shares);
        address[] memory facs = new address[](1);
        facs[0] = address(_factory2);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);
        _pm2.multicall(data, facs);
        data[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, BORROW_AMOUNT);
        _pm2.multicall(data, facs);
        vm.stopPrank();
    }

    /// @notice Documents WHY ERC4626RewardsProcessingFacet exists: the BASE facet
    ///         reads the base CollateralManager slot and sees zero debt on an
    ///         ERC4626 account, so it takes the zero-balance branch and leaves the
    ///         real ERC4626 debt UNCHANGED.
    function test_baseRewardsFacet_cannotPayERC4626Debt() public {
        _setupBaseFacetAccount();

        uint256 debtBefore = ERC4626CollateralFacet(_account2).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "precondition: ERC4626 debt == 30e6");

        // Base facet's debt read (base CollateralManager slot) must be zero here.
        // We assert behaviorally below rather than reading the private slot.

        _underlyingAsset.mint(_account2, REWARDS_AMOUNT);

        address treasury = _lc2.getTreasury();
        uint256 treasuryBefore = _underlyingAsset.balanceOf(treasury);

        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(_authorizedCaller);
        RewardsProcessingFacet(_account2).processRewards(0, REWARDS_AMOUNT, noSwap, 0);

        uint256 debtAfter = ERC4626CollateralFacet(_account2).getTotalDebt();

        // The defect: ERC4626 debt is UNCHANGED because the base facet read the
        // wrong slot, saw 0 debt, and took the zero-balance branch.
        assertEq(debtAfter, debtBefore, "base facet leaves ERC4626 debt unchanged (wrong slot)");

        // And it charged the ZERO-BALANCE fee (1%), not the protocol fee (5%),
        // confirming the zero-balance branch was taken.
        uint256 expectedZBF = (REWARDS_AMOUNT * ZERO_BALANCE_FEE_BPS) / 10000;
        assertEq(
            _underlyingAsset.balanceOf(treasury) - treasuryBefore,
            expectedZBF,
            "base facet charged zero-balance fee, not protocol fee -> zero-balance branch"
        );
    }

    // ============================================================
    // Swap guard: collateral (vault share) token must not be swappable
    // ============================================================

    /// @notice The vault/share token IS the collateral; it must never be an
    ///         input token in a rewards swap. Otherwise a swap could drain
    ///         collateral out of the account.
    function test_swap_collateralVaultToken_isBlocked() public {
        SwapMod.RouteParams memory p = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(0),
            swapData: bytes(""),
            inputToken: address(_mockVault), // collateral / share token
            inputAmount: 1,
            outputToken: address(0),
            minimumOutputAmount: 0
        });
        vm.prank(_authorizedCaller);
        vm.expectRevert("Input token not allowed");
        ERC4626RewardsProcessingFacet(_portfolioAccount).swapToRewardsToken(p);
    }

    /// @notice A non-collateral, non-rewards token stays swappable: the guard is
    ///         scoped to the collateral, not a blanket block. It clears the guard
    ///         and only fails later at the swap-target whitelist check.
    function test_swap_arbitraryToken_clearsGuard() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        SwapMod.RouteParams memory p = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(0),
            swapData: bytes(""),
            inputToken: address(other),
            inputAmount: 1,
            outputToken: address(0),
            minimumOutputAmount: 0
        });
        vm.prank(_authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(SwapMod.NotApprovedSwapTarget.selector, address(0)));
        ERC4626RewardsProcessingFacet(_portfolioAccount).swapToRewardsToken(p);
    }
}
