// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DeployRewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployRewardsProcessingFacet.s.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockBlacklistableERC20} from "../../mocks/MockBlacklistableERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";

// ======================== Mock Contracts ========================

/// @dev ERC4626 vault mock that can be paused to make deposit() revert
contract MockPausableVault {
    address public _asset;
    bool public paused;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function deposit(uint256, address) external view returns (uint256) {
        require(!paused, "Vault is paused");
        return 0;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

/// @dev Mock VotingEscrow that always reverts on increaseAmount
contract MockRevertingVE {
    address public token;
    mapping(uint256 => address) public _owners;

    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }
    mapping(uint256 => LockedBalance) public _locked;

    constructor(address _token) {
        token = _token;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function locked(uint256 tokenId) external view returns (LockedBalance memory) {
        return _locked[tokenId];
    }

    function lockPermanent(uint256) external {}

    function increaseAmount(uint256, uint256) external pure {
        revert("VE: lock expired");
    }

    // Helper for test setup
    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function setLocked(uint256 tokenId, int128 amount, bool isPermanent) external {
        _locked[tokenId] = LockedBalance(amount, 0, isPermanent);
    }
}

/**
 * =============================================================================
 * BATCH 1: P0 Tests for RewardsProcessingFacet
 *
 * Covers:
 *   Section 2:  Fee Calculations (Protocol, Lender Premium, Zero Balance, Path Selection)
 *   Section 3:  Gas Reclamation
 *   Section 4:  Active Balance Path
 *   Section 5:  Zero Balance Path
 *   Section 6:  PayBalance option
 *   Section 13: Try/Catch Graceful Degradation
 *   Section 20: Access Control
 * =============================================================================
 */
contract RewardsProcessingComprehensiveTest is Test, LocalSetup {
    RewardsProcessingFacet public rewardsProcessingFacet;
    MockOdosRouterRL public mockRouter;

    address public rewardsToken;
    address public lockedAsset;
    uint256 public rewardsAmount = 1000e6; // 1000 USDC
    address public recipient = address(0x1234);

    // Fee config defaults (from LocalSetup._setLoanConfigDefaults)
    uint256 constant TREASURY_FEE_BPS = 500;    // 5%
    uint256 constant LENDER_PREMIUM_BPS = 2000;  // 20%
    uint256 constant ZERO_BAL_FEE_BPS = 100;     // 1%
    uint256 constant BPS_DENOM = 10000;

    // Events (must redeclare for vm.expectEmit)
    event GasReclamationPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ProtocolFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ZeroBalanceFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event LenderPremiumPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event RewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 rewardsAmount, address user, address asset);
    event LoanPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ZeroBalanceRewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 remainingAmount, address indexed recipient, address asset, address indexed owner);
    event ActiveBalanceRewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event InvestedToVault(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event InvestToVaultFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event IncreaseCollateralFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);
    event CollateralIncreased(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);
    event TransferFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);
    event PaidToRecipient(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);

    function setUp() public override {
        super.setUp();

        // Deploy RewardsProcessingFacet
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_swapConfig), address(_ve), _vault);
        vm.stopPrank();

        // Initialize facet reference
        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);

        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        // Set up tokens
        rewardsToken = address(_usdc);
        lockedAsset = IVotingEscrow(_ve).token();

        // Set up UserRewardsConfig through PortfolioManager multicall
        vm.startPrank(_user);
        address[] memory pf = new address[](2);
        pf[0] = address(_portfolioFactory);
        pf[1] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](2);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, recipient);
        cd[1] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        // Approve swap target
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _fundPortfolio(uint256 amount) internal {
        deal(rewardsToken, _portfolioAccount, amount);
    }

    function _noSwap() internal pure returns (SwapMod.RouteParams[4] memory s) {}

    function _processRewards(uint256 amount, uint256 gasReclamation) internal {
        vm.prank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(_tokenId, amount, _noSwap(), gasReclamation);
    }

    function _processRewardsWithSwap(uint256 amount, uint256 gasReclamation, SwapMod.RouteParams[4] memory swapParams) internal {
        vm.prank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(_tokenId, amount, swapParams, gasReclamation);
    }

    function _createDebt(uint256 borrowAmount) internal {
        // Fund vault so borrow can succeed
        deal(address(_usdc), _vault, (borrowAmount * BPS_DENOM) / 8000 + 1);
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, borrowAmount);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _setZeroBalanceDistribution(UserRewardsConfig.DistributionEntry[] memory entries) internal {
        _approveAllowlistForEntries(entries);
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry memory entry) internal {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = entry;
        _approveAllowlistForEntries(entries);
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setActiveBalanceDistribution.selector, entry);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _approveAllowlistForEntries(UserRewardsConfig.DistributionEntry[] memory entries) internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].option == UserRewardsConfig.RewardsOption.InvestToVault) {
                _swapConfig.setApprovedVault(entries[i].target, true);
            } else if (
                entries[i].option == UserRewardsConfig.RewardsOption.PayToRecipient
                    && entries[i].outputToken != address(0)
            ) {
                _swapConfig.setApprovedOutputToken(entries[i].outputToken, true);
            }
        }
        vm.stopPrank();
    }

    function _getOwner() internal view returns (address) {
        return _portfolioFactoryConfig.owner();
    }

    /**
     * @dev Replace the registered RewardsProcessingFacet with a fresh one whose
     *      vault.asset() returns `token`. This makes `getRewardsToken()` return
     *      `token` so that processRewards uses it as the rewards asset.
     *
     *      Used by the bugfix tests that need the blacklistable mock token to
     *      flow through processRewards. The mock vault is just an `asset()`
     *      shim — these tests run the zero-balance path so vault.deposit is
     *      never invoked.
     */
    function _useTokenAsRewardsAsset(address token) internal {
        // Find the currently registered RewardsProcessingFacet by its selector
        address oldFacet = _facetRegistry.getFacetForSelector(RewardsProcessingFacet.processRewards.selector);

        // Mock vault that simply reports `token` as its underlying asset
        MockPausableVault mockVault = new MockPausableVault(token);

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        address _veToken = IVotingEscrow(_ve).token();
        VotingEscrowRewardsProcessingFacet newFacet = new VotingEscrowRewardsProcessingFacet(
            address(_portfolioFactory),
            address(_swapConfig),
            address(_ve),
            address(mockVault),
            _veToken,
            _veToken
        );
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RewardsProcessingFacet.processRewards.selector;
        selectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        selectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        selectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        selectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _facetRegistry.replaceFacet(oldFacet, address(newFacet), selectors, "RewardsProcessingFacet");
        vm.stopPrank();
    }

    function _currentEpochStart() internal view returns (uint256) {
        return (block.timestamp / 1 weeks) * 1 weeks;
    }

    // ====================================================================
    // Section 2: Fee Calculations
    // ====================================================================

    // ── 2.1 Protocol Fee ────────────────────────────────────────────────

    function test_protocolFee_standardCalculation() public {
        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        uint256 expectedFee = (rewards * TREASURY_FEE_BPS) / BPS_DENOM; // 50 USDC
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, expectedFee, "Protocol fee should be 5% of rewards");
    }

    function test_protocolFee_zeroTreasuryFee_rejectsZero() public {
        // BUG FIX 1: setTreasuryFee now rejects 0 to prevent downstream issues
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert("Treasury fee must be > 0");
        _loanConfig.setTreasuryFee(0);
    }

    function test_protocolFee_maxTreasuryFee() public {
        // Test with max combined fees: treasury=3000 + lender=2000 = 5000 (max)
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setTreasuryFee(3000);
        vm.stopPrank();

        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        uint256 expectedFee = (rewards * 3000) / BPS_DENOM; // 300 USDC (30%)
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, expectedFee, "Protocol fee at 30%");
    }

    function test_protocolFee_maxCombinedWithZeroLenderReverts() public {
        // BUG FIX 1: setLenderPremium now rejects 0, so this combination is impossible
        // at the config level. The setter itself reverts before we ever reach processRewards.
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert("Lender premium must be > 0");
        _loanConfig.setLenderPremium(0);
        vm.stopPrank();
    }

    function test_protocolFee_roundingDown() public {
        // BUG DOCUMENTATION: When both protocolFee and lenderPremium round to 0 due to
        // small rewardsAmount, depositRewards(0) is still called and reverts.
        // This test uses rewards large enough that lenderPremium > 0 to avoid that bug.
        _createDebt(500e6);
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setTreasuryFee(100); // 1%

        // With treasuryFee=100 bps and rewards=99: 99*100/10000 = 0 (floor)
        // But lenderPremium=2000 bps: 99*2000/10000 = 19, which is > 0, so depositRewards won't revert
        uint256 rewards = 99;
        deal(rewardsToken, _portfolioAccount, rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        // 99 * 100 / 10000 = 0
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, 0, "Rounding should floor to 0");
    }

    function test_protocolFee_emitsEvent() public {
        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 expectedFee = (rewards * TREASURY_FEE_BPS) / BPS_DENOM;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, false, true);
        emit ProtocolFeePaid(_currentEpochStart(), _tokenId, expectedFee, portfolioOwner, rewardsToken);

        _processRewards(rewards, 0);
    }

    // ── 2.2 Lender Premium ──────────────────────────────────────────────

    function test_lenderPremium_standardCalculation() public {
        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 vaultBefore = IERC20(rewardsToken).balanceOf(_vault);

        _processRewards(rewards, 0);

        // Lender premium goes to vault via loan contract depositRewards
        uint256 expectedPremium = (rewards * LENDER_PREMIUM_BPS) / BPS_DENOM; // 200 USDC
        uint256 vaultAfter = IERC20(rewardsToken).balanceOf(_vault);
        // Vault receives premium + debt payment
        assertGe(vaultAfter - vaultBefore, expectedPremium, "Vault should receive at least lender premium");
    }

    function test_lenderPremium_zeroLenderPremium_rejectsZero() public {
        // BUG FIX 1: setLenderPremium now rejects 0 to prevent depositRewards(0) revert.
        // The fix is at the config level — the setter itself rejects 0.
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert("Lender premium must be > 0");
        _loanConfig.setLenderPremium(0);
    }

    function test_lenderPremium_usesForceApprove() public {
        // ForceApprove handles tokens that require resetting approval to 0 before setting new value.
        // This test verifies it doesn't revert for the USDC-like token.
        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        // Should not revert — forceApprove handles non-zero to non-zero
        _processRewards(rewards, 0);
    }

    function test_lenderPremium_emitsEvent() public {
        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 expectedPremium = (rewards * LENDER_PREMIUM_BPS) / BPS_DENOM;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, false, true);
        emit LenderPremiumPaid(_currentEpochStart(), _tokenId, expectedPremium, portfolioOwner, rewardsToken);

        _processRewards(rewards, 0);
    }

    function test_lenderPremium_combinedWithProtocolFee() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setTreasuryFee(1000);  // 10%
        _loanConfig.setLenderPremium(2000); // 20%
        vm.stopPrank();

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);
        uint256 vaultBefore = IERC20(rewardsToken).balanceOf(_vault);

        _processRewards(rewards, 0);

        uint256 protocolFee = (rewards * 1000) / BPS_DENOM; // 100
        uint256 lenderPremium = (rewards * 2000) / BPS_DENOM; // 200
        uint256 amountForDebt = rewards - protocolFee - lenderPremium; // 700

        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, protocolFee, "Owner gets protocol fee");
        // Vault receives lender premium + debt payment
        uint256 vaultAfter = IERC20(rewardsToken).balanceOf(_vault);
        assertEq(vaultAfter - vaultBefore, lenderPremium + amountForDebt, "Vault gets premium + debt payment");
    }

    // ── 2.3 Zero Balance Fee ────────────────────────────────────────────

    function test_zeroBalanceFee_standardCalculation() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        uint256 expectedFee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM; // 10 USDC
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, expectedFee, "Zero balance fee should be 1%");
    }

    function test_zeroBalanceFee_zeroFee_rejectsZero() public {
        // BUG FIX 1: setZeroBalanceFee now rejects 0 to prevent division/fee issues.
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert("Zero balance fee must be > 0");
        _loanConfig.setZeroBalanceFee(0);
    }

    function test_zeroBalanceFee_maxFee() public {
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(10000); // 100%

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, rewards, "100% fee takes all rewards");
        assertEq(IERC20(rewardsToken).balanceOf(recipient), 0, "Recipient gets nothing");
    }

    function test_zeroBalanceFee_emitsEvent() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 expectedFee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, false, true);
        emit ZeroBalanceFeePaid(_currentEpochStart(), _tokenId, expectedFee, portfolioOwner, rewardsToken);

        _processRewards(rewards, 0);
    }

    function test_zeroBalanceFee_roundingWithSmallAmount() public {
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(1); // 0.01%

        uint256 rewards = 1; // 1 wei
        _fundPortfolio(rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        // 1 * 1 / 10000 = 0
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, 0, "Fee rounds to 0 for tiny amount");
    }

    // ── 2.4 Fee Path Selection ──────────────────────────────────────────

    function test_feePath_debtUsesProtocolAndLenderFees() public {
        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        // Protocol fee = 50 USDC (not zero balance fee of 10)
        uint256 protocolFee = (rewards * TREASURY_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, protocolFee, "Should use protocol fee path, not zero balance");
    }

    function test_feePath_noDebtUsesZeroBalanceFee() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        // Zero balance fee = 10 USDC (not protocol fee of 50)
        uint256 zeroBalFee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, zeroBalFee, "Should use zero balance fee path");
    }

    function test_feePath_debtRepaidMidEpoch() public {
        // Create small debt so it gets fully repaid during processRewards
        // hasDebt is checked once at start, so active path fees are used
        _createDebt(100e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        address owner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(owner);

        _processRewards(rewards, 0);

        // Debt path was used, so protocol fee charged (not zero balance fee)
        uint256 protocolFee = (rewards * TREASURY_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(owner) - ownerBefore, protocolFee, "Active path fees even when debt fully repaid");
    }

    // ====================================================================
    // Section 3: Gas Reclamation
    // ====================================================================

    function test_gasReclamation_standardPayment() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 gasRecl = 20e6; // 20 USDC, cap = 50 USDC
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, gasRecl);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, gasRecl, "Caller receives gas reclamation");
    }

    function test_gasReclamation_exceedsCap() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 gasRecl = 100e6; // 100 USDC, cap = 50 USDC
        uint256 cap = rewards * 5 / 100;
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, gasRecl);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, cap, "Gas reclamation capped at 5%");
    }

    function test_gasReclamation_exactlyCap() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 gasRecl = 50e6; // exactly 5%
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, gasRecl);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, gasRecl, "Exactly at cap");
    }

    function test_gasReclamation_zero() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, 0);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, 0, "No gas reclamation");
    }

    function test_gasReclamation_capCalculation_smallRewards() public {
        uint256 rewards = 10e6; // 10 USDC, cap = 0.5 USDC
        _fundPortfolio(rewards);

        uint256 gasRecl = 1e6; // 1 USDC, exceeds cap of 0.5 USDC
        uint256 cap = rewards * 5 / 100; // 500000 (0.5 USDC)
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, gasRecl);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, cap, "Cap at 0.5 USDC for 10 USDC rewards");
    }

    function test_gasReclamation_emitsEvent() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 gasRecl = 20e6;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, false, true);
        emit GasReclamationPaid(_currentEpochStart(), _tokenId, gasRecl, portfolioOwner, rewardsToken);

        _processRewards(rewards, gasRecl);
    }

    function test_gasReclamation_capCalculation_roundingDown() public {
        // 3 * 5 / 100 = 0 (floor division)
        uint256 rewards = 3;
        _fundPortfolio(rewards);

        // Anything > 0 should be capped to 0 by the cap calculation, meaning no transfer
        // But if gasReclamation > 0 and cap == 0, gasReclamation gets capped to 0
        // The code sets gasReclamation = gasReclamationCap when gasReclamation > cap
        // Since 1 > 0, gasReclamation becomes 0
        // With gasReclamation == 0, the if(gasReclamation > 0) check fails, no transfer
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, 1);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, 0, "Gas capped to 0 for tiny rewards");
    }

    function test_gasReclamation_afterFees_capOnOriginal() public {
        // Gas cap computed on original rewardsAmount, not post-fees
        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 gasRecl = 40e6;
        uint256 cap = rewards * 5 / 100; // 50 USDC on original
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, gasRecl);

        // 40 < 50 cap, so full 40 paid
        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, gasRecl, "Gas cap uses original rewardsAmount");
    }

    function test_gasReclamation_afterFees_zeroBalance() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 gasRecl = 40e6;
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, gasRecl);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, gasRecl, "Gas cap on original for zero balance path");
    }

    function test_gasReclamation_consumesAllRemaining() public {
        // After 100% zero balance fee, remaining = 0. Gas reclamation would underflow.
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(9500); // 95%

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // remaining after fee = 50 USDC. Gas cap = 5% of 1000 = 50. gasRecl = 50.
        // remaining - gasReclamation = 50 - 50 = 0. Should work.
        uint256 callerBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);

        _processRewards(rewards, 50e6);

        assertEq(IERC20(rewardsToken).balanceOf(_authorizedCaller) - callerBefore, 50e6, "Gas takes all remaining");
        assertEq(IERC20(rewardsToken).balanceOf(recipient), 0, "Nothing left for recipient");
    }

    // ====================================================================
    // Section 4: Active Balance Path
    // ====================================================================

    // ── 4.1 Standard Debt Repayment ─────────────────────────────────────

    function test_activeBalance_fullDebtRepayment_noExcess() public {
        // Create debt where post-fee amount exactly matches debt
        _createDebt(500e6);
        uint256 debt = CollateralFacet(_portfolioAccount).getTotalDebt();

        // Calculate rewards needed so remaining after fees = debt
        // remaining = rewards - protocolFee - lenderPremium
        // remaining = rewards * (1 - 0.05 - 0.20) = rewards * 0.75
        uint256 rewards = (debt * BPS_DENOM) / (BPS_DENOM - TREASURY_FEE_BPS - LENDER_PREMIUM_BPS);
        // Adjust for rounding: add 1 to ensure enough
        rewards += 1;
        deal(rewardsToken, _portfolioAccount, rewards);

        _processRewards(rewards, 0);

        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Debt should be fully repaid");
    }

    function test_activeBalance_fullDebtRepayment_withExcess() public {
        _createDebt(100e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debt = CollateralFacet(_portfolioAccount).getTotalDebt();
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 vaultSharesBefore = IERC20(_vault).balanceOf(portfolioOwner);

        _processRewards(rewards, 0);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt fully repaid");
        // Excess deposited to vault as shares for owner
        uint256 vaultSharesAfter = IERC20(_vault).balanceOf(portfolioOwner);
        assertGt(vaultSharesAfter, vaultSharesBefore, "Owner receives vault shares from excess");
    }

    function test_activeBalance_partialDebtRepayment() public {
        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        _processRewards(rewards, 0);

        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 protocolFee = (rewards * TREASURY_FEE_BPS) / BPS_DENOM;
        uint256 lenderPremium = (rewards * LENDER_PREMIUM_BPS) / BPS_DENOM;
        uint256 amountForDebt = rewards - protocolFee - lenderPremium;

        assertEq(debtBefore - debtAfter, amountForDebt, "Debt reduced by remaining after fees");
        assertGt(debtAfter, 0, "Still has remaining debt");
    }

    function test_activeBalance_excessDepositedToVault() public {
        _createDebt(100e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 sharesBefore = IERC20(_vault).balanceOf(portfolioOwner);

        _processRewards(rewards, 0);

        uint256 sharesAfter = IERC20(_vault).balanceOf(portfolioOwner);
        assertGt(sharesAfter - sharesBefore, 0, "Vault shares minted to owner from excess");
    }

    function test_activeBalance_emitsLoanPaid() public {
        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 protocolFee = (rewards * TREASURY_FEE_BPS) / BPS_DENOM;
        uint256 lenderPremium = (rewards * LENDER_PREMIUM_BPS) / BPS_DENOM;
        uint256 amountForDebt = rewards - protocolFee - lenderPremium;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, false, true);
        emit LoanPaid(_currentEpochStart(), _tokenId, amountForDebt, portfolioOwner, rewardsToken);

        _processRewards(rewards, 0);
    }

    function test_activeBalance_vaultApproveResetAfterDeposit() public {
        _createDebt(100e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        _processRewards(rewards, 0);

        // Check approval from portfolio to vault is reset to 0
        uint256 allowance = IERC20(rewardsToken).allowance(_portfolioAccount, _vault);
        assertEq(allowance, 0, "Vault allowance reset to 0 after deposit");
    }

    // ── 4.2 With Active Balance Distribution ────────────────────────────

    function test_activeBalance_distributionThenDebt() public {
        // Set 25% PayBalance active distribution
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 25,
            outputToken: address(0),
            target: recipient
        }));

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        _processRewards(rewards, 0);

        uint256 protocolFee = (rewards * TREASURY_FEE_BPS) / BPS_DENOM;
        uint256 lenderPremium = (rewards * LENDER_PREMIUM_BPS) / BPS_DENOM;
        uint256 postFees = rewards - protocolFee - lenderPremium; // 750
        uint256 distributionAmount = rewards * 25 / 100; // 25% of total = 250
        if (distributionAmount > postFees) distributionAmount = postFees;

        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);
        assertEq(recipientAfter - recipientBefore, distributionAmount, "Recipient gets 25% of total rewards");
    }

    function test_activeBalance_distribution10Percent() public {
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 10,
            outputToken: address(0),
            target: recipient
        }));

        _createDebt(500e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        _processRewards(rewards, 0);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 distributionAmount = rewards * 10 / 100; // 10% of total = 100
        if (distributionAmount > postFees) distributionAmount = postFees;

        assertEq(IERC20(rewardsToken).balanceOf(recipient) - recipientBefore, distributionAmount, "10% of total to recipient");
    }

    function test_activeBalance_distributionReducesDebtPayment() public {
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 25,
            outputToken: address(0),
            target: recipient
        }));

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        _processRewards(rewards, 0);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 distributionAmount = rewards * 25 / 100; // 25% of total = 250
        if (distributionAmount > postFees) distributionAmount = postFees;
        uint256 amountForDebt = postFees - distributionAmount;
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();

        assertEq(debtBefore - debtAfter, amountForDebt, "Debt reduced by remaining post-fees after ABD");
    }

    function test_activeBalance_noDistributionSet() public {
        // No active balance distribution configured (default)
        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        _processRewards(rewards, 0);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();

        assertEq(debtBefore - debtAfter, postFees, "Full post-fees amount goes to debt");
    }

    function test_activeBalance_emitsActiveBalanceRewardsProcessed() public {
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 25,
            outputToken: address(0),
            target: recipient
        }));

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 distributionAmount = rewards * 25 / 100; // 25% of total = 250
        if (distributionAmount > postFees) distributionAmount = postFees;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, false, true);
        emit ActiveBalanceRewardsProcessed(_currentEpochStart(), _tokenId, distributionAmount, rewardsToken, portfolioOwner);

        _processRewards(rewards, 0);
    }

    function test_activeBalance_distributionWithZeroRemaining() public {
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 25,
            outputToken: address(0),
            target: recipient
        }));

        // Set fees high: treasury=3000 + lender=2000 = 5000 (max combined), leaving 50%
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setTreasuryFee(3000);
        vm.stopPrank();

        _createDebt(2000e6);
        uint256 rewards = 100e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        // remaining after 30%+20% fees = 50. gas cap = 5% of 100 = 5.
        // Use gasReclamation = 50 but cap at 5, leaving 45 remaining
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        _processRewards(rewards, 50e6);

        // Post-fees = 100 - 30 - 20 = 50, gas = 5, remaining = 45
        // ABD = 25% of total (100) = 25, capped at remaining (45) = 25
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 protocolFee = (rewards * 3000 / BPS_DENOM);
        uint256 lenderPrem = (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 postFees = rewards - protocolFee - lenderPrem;
        uint256 gasActual = rewards * 5 / 100;
        uint256 remaining = postFees - gasActual;
        uint256 expectedDistribution = rewards * 25 / 100;
        if (expectedDistribution > remaining) expectedDistribution = remaining;
        assertEq(recipientAfter - recipientBefore, expectedDistribution, "Distribution amount from total rewards, capped at remaining");
    }

    // ====================================================================
    // Section 5: Zero Balance Path
    // ====================================================================

    // ── 5.1 No Distribution Configured ──────────────────────────────────

    function test_zeroBalance_noDistribution_allToRecipient() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "All post-fee to recipient");
    }

    function test_zeroBalance_noDistribution_noRecipient() public {
        // Clear recipient
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, address(0));
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 ownerTokensBefore = IERC20(rewardsToken).balanceOf(portfolioOwner);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        // config.owner() gets fee, portfolioOwner (fallback recipient) gets remainder
        // Note: FORTY_ACRES_DEPLOYER is both config.owner() and portfolioFactory deployer.
        // _user is the portfolio owner.
        uint256 ownerTokensAfter = IERC20(rewardsToken).balanceOf(portfolioOwner);
        assertEq(ownerTokensAfter - ownerTokensBefore, rewards - fee, "Portfolio owner is fallback recipient");
    }

    function test_zeroBalance_emitsZeroBalanceRewardsProcessed() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 postFees = rewards - fee;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, true, true);
        emit ZeroBalanceRewardsProcessed(_currentEpochStart(), _tokenId, postFees, recipient, rewardsToken, portfolioOwner);

        _processRewards(rewards, 0);
    }

    // ── 5.2 Single Distribution Entry ───────────────────────────────────

    function test_zeroBalance_singleEntry_100percent() public {
        address target1 = address(0xBEEF01);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: target1
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        assertEq(IERC20(rewardsToken).balanceOf(target1), distributable, "100% to single entry");
        assertEq(IERC20(rewardsToken).balanceOf(recipient), 0, "Nothing to default recipient");
    }

    function test_zeroBalance_singleEntry_50percent() public {
        address target1 = address(0xBEEF01);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 50,
            outputToken: address(0),
            target: target1
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 entryAmount = distributable * 50 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(target1), entryAmount, "50% to entry");
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - entryAmount, "50% remainder to recipient");
    }

    function test_zeroBalance_singleEntry_20percent() public {
        address target1 = address(0xBEEF01);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 20,
            outputToken: address(0),
            target: target1
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 entryAmount = distributable * 20 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(target1), entryAmount, "20% to entry");
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - entryAmount, "80% remainder to recipient");
    }

    // ── 5.3 Multiple Distribution Entries ───────────────────────────────

    function test_zeroBalance_twoEntries_50_50() public {
        address t1 = address(0xBEEF01);
        address t2 = address(0xBEEF02);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 50, outputToken: address(0), target: t1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 50, outputToken: address(0), target: t2
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 amount1 = distributable * 50 / 100;
        uint256 amount2 = distributable * 50 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(t1), amount1, "50% to t1");
        assertEq(IERC20(rewardsToken).balanceOf(t2), amount2, "50% to t2");
    }

    function test_zeroBalance_threeEntries_30_30_30() public {
        address t1 = address(0xBEEF01);
        address t2 = address(0xBEEF02);
        address t3 = address(0xBEEF03);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](3);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 30, outputToken: address(0), target: t1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 30, outputToken: address(0), target: t2
        });
        entries[2] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 30, outputToken: address(0), target: t3
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 each = distributable * 30 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(t1), each, "30% to t1");
        assertEq(IERC20(rewardsToken).balanceOf(t2), each, "30% to t2");
        assertEq(IERC20(rewardsToken).balanceOf(t3), each, "30% to t3");
        // Remainder: 10% to default recipient
        uint256 remainder = distributable - (each * 3);
        assertEq(IERC20(rewardsToken).balanceOf(recipient), remainder, "10% remainder to recipient");
    }

    function test_zeroBalance_fourEntries_25_25_25_25() public {
        address t1 = address(0xBEEF01);
        address t2 = address(0xBEEF02);
        address t3 = address(0xBEEF03);
        address t4 = address(0xBEEF04);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](4);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 25, outputToken: address(0), target: t1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 25, outputToken: address(0), target: t2
        });
        entries[2] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 25, outputToken: address(0), target: t3
        });
        entries[3] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 25, outputToken: address(0), target: t4
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 each = distributable * 25 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(t1), each, "25% to t1");
        assertEq(IERC20(rewardsToken).balanceOf(t2), each, "25% to t2");
        assertEq(IERC20(rewardsToken).balanceOf(t3), each, "25% to t3");
        assertEq(IERC20(rewardsToken).balanceOf(t4), each, "25% to t4");
    }

    function test_zeroBalance_twoEntries_80_20() public {
        address t1 = address(0xBEEF01);
        address t2 = address(0xBEEF02);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 80, outputToken: address(0), target: t1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 20, outputToken: address(0), target: t2
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 a1 = distributable * 80 / 100;
        uint256 a2 = distributable * 20 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(t1), a1, "80% to t1");
        assertEq(IERC20(rewardsToken).balanceOf(t2), a2, "20% to t2");
    }

    function test_zeroBalance_remainderAfterDistribution() public {
        address t1 = address(0xBEEF01);
        address t2 = address(0xBEEF02);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 30, outputToken: address(0), target: t1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 30, outputToken: address(0), target: t2
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 each = distributable * 30 / 100;
        uint256 remainder = distributable - (each * 2);

        assertEq(IERC20(rewardsToken).balanceOf(recipient), remainder, "40% remainder to recipient");
    }

    // ── 5.4 Percentage Calculation ──────────────────────────────────────

    function test_zeroBalance_percentageOnDistributable() public {
        // Distributable = remaining (post-gas), verify percentage is on that
        address t1 = address(0xBEEF01);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 50, outputToken: address(0), target: t1
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 gasRecl = 20e6;

        _processRewards(rewards, gasRecl);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee - gasRecl; // post-gas
        uint256 expectedEntry = distributable * 50 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(t1), expectedEntry, "Percentage on post-gas distributable");
    }

    function test_zeroBalance_percentageRounding() public {
        // Test floor division rounding with 33% distribution.
        // Use minimum zero balance fee (1 bps) and adjust math accordingly.
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(1); // 0.01%

        address t1 = address(0xBEEF01);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 33, outputToken: address(0), target: t1
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000000; // 1 USDC (enough for fee to be nonzero or zero via rounding)
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * 1) / BPS_DENOM; // 1000000 * 1 / 10000 = 100
        uint256 distributable = rewards - fee; // 999900
        uint256 entryAmount = distributable * 33 / 100; // 329967
        assertEq(IERC20(rewardsToken).balanceOf(t1), entryAmount, "Floor division rounding");
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - entryAmount, "Remainder to recipient");
    }

    function test_zeroBalance_entryAmountCappedByRemaining() public {
        // Two entries at 60% each. First uses 60%, second should be capped to remaining 40%.
        // But setter requires total <= 100%, so we use entries that individually are within bounds
        // but cumulative rounding could cause issues.
        // Actually, the setter requires each entry >= 20% and total <= 100%, so 60+60=120 would revert.
        // Instead, use 80+20=100. First consumes 80%, remaining = 20%. Second percentage = 20%.
        // distributable*20/100 should equal remaining exactly.
        address t1 = address(0xBEEF01);
        address t2 = address(0xBEEF02);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 80, outputToken: address(0), target: t1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 20, outputToken: address(0), target: t2
        });
        _setZeroBalanceDistribution(entries);

        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(1); // 0.01% minimum

        uint256 rewards = 10000000; // 10 USDC for clean math
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * 1) / BPS_DENOM; // 10000000 * 1 / 10000 = 1000
        uint256 distributable = rewards - fee; // 9999000
        uint256 amount1 = distributable * 80 / 100;
        uint256 amount2 = distributable * 20 / 100;
        assertEq(IERC20(rewardsToken).balanceOf(t1), amount1, "Entry 1 gets 80%");
        assertEq(IERC20(rewardsToken).balanceOf(t2), amount2, "Entry 2 gets 20%");
        // Remainder = distributable - amount1 - amount2
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - amount1 - amount2, "Dust remainder to recipient");
    }

    function test_zeroBalance_lastEntryCapped() public {
        // 3 entries at 40%, 40%, 20% = 100%. Entries with 40% each individually valid (>=20).
        address t1 = address(0xBEEF01);
        address t2 = address(0xBEEF02);
        address t3 = address(0xBEEF03);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](3);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 40, outputToken: address(0), target: t1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 40, outputToken: address(0), target: t2
        });
        entries[2] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance, percentage: 20, outputToken: address(0), target: t3
        });
        _setZeroBalanceDistribution(entries);

        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(1); // 0.01% minimum

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * 1) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 a1 = distributable * 40 / 100;
        uint256 a2 = distributable * 40 / 100;
        uint256 a3 = distributable * 20 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(t1), a1, "40% to t1");
        assertEq(IERC20(rewardsToken).balanceOf(t2), a2, "40% to t2");
        assertEq(IERC20(rewardsToken).balanceOf(t3), a3, "20% to t3 (capped by remaining)");
    }

    // ====================================================================
    // Section 6: PayBalance Option
    // ====================================================================

    function test_payBalance_toExplicitTarget() public {
        address target = address(0xCAFE);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(target), rewards - fee, "Tokens to explicit target");
    }

    function test_payBalance_noTarget_usesDefaultRecipient() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: address(0) // falls back to _getRecipient()
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "Falls back to default recipient");
    }

    function test_payBalance_returnsFullAmount() public {
        // PayBalance always returns amount consumed, even on success
        // Verify by checking that remaining is properly reduced
        address target = address(0xCAFE);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 50,
            outputToken: address(0),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 entryAmount = distributable * 50 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(target), entryAmount, "50% to target");
        // Remainder goes to default recipient, proving PayBalance consumed exactly entryAmount
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - entryAmount, "Remainder proves full amount consumed");
    }

    function test_payBalance_zeroBalancePath() public {
        // PayBalance in zero balance distribution - verify correct flow
        address target = address(0xCAFE);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(target), rewards - fee, "Full distributable to PayBalance entry");
    }

    function test_payBalance_activeBalancePath() public {
        address target = address(0xCAFE);
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 20,
            outputToken: address(0),
            target: target
        }));

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        _processRewards(rewards, 0);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 distributionAmount = rewards * 20 / 100; // 20% of total = 200
        if (distributionAmount > postFees) distributionAmount = postFees;
        uint256 forDebt = postFees - distributionAmount;

        assertEq(IERC20(rewardsToken).balanceOf(target), distributionAmount, "20% of total PayBalance in active path");
        assertEq(debtBefore - CollateralFacet(_portfolioAccount).getTotalDebt(), forDebt, "Rest goes to debt");
    }

    // For PayBalance trySafeTransfer failure + sendToWalletAccount, we need a wallet factory.
    // This is tested in the try/catch degradation section below.

    function test_payBalance_trySafeTransfer_success() public {
        address target = address(0xCAFE);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(target), rewards - fee, "trySafeTransfer succeeds");
    }

    // ====================================================================
    // Section 13: Try/Catch Graceful Degradation
    // ====================================================================

    // ── 13.1 InvestToVault Degradation ───────────────────────────────────

    function test_investToVault_graceful_noSwap_zeroBalance_allToRecipient() public {
        // Create a pausable vault that will fail on deposit
        MockPausableVault pausableVault = new MockPausableVault(rewardsToken);
        pausableVault.setPaused(true);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(pausableVault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        // InvestToVault fails (no swap) -> returns 0 -> tokens stay in remaining -> goes to recipient
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "All to recipient on vault failure");
    }

    function test_investToVault_graceful_noSwap_activeBalance_allToDebt() public {
        // Create a pausable vault
        MockPausableVault pausableVault = new MockPausableVault(rewardsToken);
        pausableVault.setPaused(true);

        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 25,
            outputToken: address(0),
            target: address(pausableVault)
        }));

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        _processRewards(rewards, 0);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        // InvestToVault fails (no swap) -> returns 0 -> all postFees goes to debt
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore - debtAfter, postFees, "All post-fees to debt when vault fails");
    }

    function test_investToVault_graceful_postSwap_tokensToWallet() public {
        // This test requires wallet factory setup. Create a wallet factory and account.
        // Deploy a second factory with salt bytes32(0) as the "wallet factory"
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory walletFactory, FacetRegistry walletRegistry) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();

        // Create wallet account for the user
        address walletAccount = walletFactory.createAccount(_user);

        // Create a pausable vault that accepts a DIFFERENT asset (forces swap)
        MockERC20 otherToken = new MockERC20("Other", "OTH", 6);
        MockPausableVault pausableVault = new MockPausableVault(address(otherToken));
        pausableVault.setPaused(true);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(pausableVault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        // Prepare swap: USDC -> OTH
        uint256 swapOut = 500e6;
        deal(address(otherToken), address(mockRouter), swapOut);

        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            rewardsToken,
            address(otherToken),
            distributable,
            swapOut,
            _portfolioAccount
        );

        vm.prank(_portfolioAccount);
        IERC20(rewardsToken).approve(address(mockRouter), distributable);

        SwapMod.RouteParams[4] memory swapParams;
        swapParams[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: swapData,
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: 0
        });

        vm.prank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(_tokenId, rewards, swapParams, 0);

        // Post-swap: vault deposit fails -> swapped tokens sent to wallet account
        assertEq(otherToken.balanceOf(walletAccount), swapOut, "Swapped tokens sent to wallet on vault failure");
    }

    function test_investToVault_graceful_mixedEntries_oneFails() public {
        // Entry 0: InvestToVault (fails), Entry 1: PayBalance (succeeds)
        MockPausableVault pausableVault = new MockPausableVault(rewardsToken);
        pausableVault.setPaused(true);

        address target = address(0xCAFE);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 50,
            outputToken: address(0),
            target: address(pausableVault)
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 50,
            outputToken: address(0),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 entryAmount = distributable * 50 / 100;

        // Entry 0 (InvestToVault fails, no swap) returns 0 -> tokens stay in remaining
        // Entry 1 gets 50% of distributable
        assertEq(IERC20(rewardsToken).balanceOf(target), entryAmount, "PayBalance entry processes normally");
        // Remainder (entry 0's share that stayed) goes to default recipient
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - entryAmount, "Failed entry's share to recipient");
    }

    // ── 13.2 IncreaseCollateral Degradation ─────────────────────────────

    function test_increaseCollateral_graceful_noSwap_tokensStay() public {
        // When collateral token == rewards token and lock fails, returns 0 -> tokens stay
        // This requires rewardsToken == lockedAsset. Since lockedAsset is AERO and the
        // default vault asset is USDC, we swap the facet's vault to one that reports AERO.
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 50,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        // Use tokenId=0 so VotingEscrowRewardsProcessingFacet._increaseCollateral returns 0
        uint256 rewards = 1000e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        // Process with tokenId=0
        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(0, rewards, noSwap, 0);

        // IncreaseCollateral returns 0 (tokenId=0) -> tokens stay -> all goes to recipient
        // Recipient here is the configured `recipient` address
        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        assertEq(IERC20(lockedAsset).balanceOf(recipient), rewards - fee, "All to recipient when lock fails");
    }

    function test_increaseCollateral_graceful_activeBalance_fallsToDebt() public {
        // Active balance path: IncreaseCollateral fails (tokenId=0) -> returns 0 -> all to debt
        // Need to set rewards token to AERO (same as collateral) for the no-swap path
        // But active balance requires debt, and with debt, rewardsToken = vaultAsset (USDC), not AERO.
        // So the only way to have same-token IncreaseCollateral in active path is if collateralToken == USDC.
        // Since our setup has AERO as collateral, we test with tokenId=0 which short-circuits to return 0 anyway.

        // Use the USDC->AERO swap path but with tokenId=0 which returns 0 in _increaseCollateral
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 25,
            outputToken: address(0),
            target: address(0)
        }));

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        // Process with tokenId=0 and no swap params -> IncreaseCollateral requires swap target but
        // _increaseCollateral checks tokenId==0 first and returns 0 immediately
        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(0, rewards, noSwap, 0);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        // IncreaseCollateral returns 0 (tokenId=0), so full postFees goes to debt
        assertEq(debtBefore - debtAfter, postFees, "All post-fees to debt when collateral increase fails");
    }

    function test_increaseCollateral_graceful_postSwap_tokensToWallet() public {
        // Need wallet factory for this test
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory walletFactory, ) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        address walletAccount = walletFactory.createAccount(_user);

        // IncreaseCollateral with swap: USDC -> AERO, then increaseAmount fails
        // We'll use a mock VE that reverts. But our setup uses MockVotingEscrow which doesn't revert.
        // Actually, VotingEscrowRewardsProcessingFacet._increaseLock wraps increaseAmount in try/catch.
        // If it fails, it returns 0. But _increaseCollateral checks: if (used == 0 && swap happened),
        // send swapped tokens to wallet.
        // To trigger: make the VE's increaseAmount fail.
        // MockVotingEscrow.increaseAmount succeeds normally... We need to make it fail.
        // The simplest approach: don't approve AERO to the VE. But the code does approve before calling.
        // Actually, the easiest way: the tokenId must be valid in MockVE. If we pass a non-existent tokenId,
        // MockVotingEscrow will revert because ownerOf checks _owners[tokenId] != address(0).
        // But _increaseLock wraps it in try/catch, so it will catch and return 0.

        // Create debt so we're in active path with USDC rewards
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 25,
            outputToken: address(0),
            target: address(0)
        }));

        _createDebt(2000e6);
        uint256 rewards = 1000e6;
        deal(rewardsToken, _portfolioAccount, rewards);

        uint256 postFees = rewards - (rewards * TREASURY_FEE_BPS / BPS_DENOM) - (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 amountToSwap = postFees * 25 / 100;
        uint256 swapOut = 200e18;

        deal(lockedAsset, address(mockRouter), swapOut);

        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            rewardsToken,
            lockedAsset,
            amountToSwap,
            swapOut,
            _portfolioAccount
        );

        vm.prank(_portfolioAccount);
        IERC20(rewardsToken).approve(address(mockRouter), amountToSwap);

        SwapMod.RouteParams[4] memory swapParams;
        swapParams[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: swapData,
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: 0
        });

        // Use a non-existent tokenId (999) so increaseAmount fails in the try/catch
        uint256 fakeTokenId = 999;

        vm.prank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(fakeTokenId, rewards, swapParams, 0);

        // After swap, lock fails -> swapped AERO tokens sent to wallet
        assertEq(IERC20(lockedAsset).balanceOf(walletAccount), swapOut, "Swapped tokens sent to wallet on lock failure");
    }

    // ── 13.3 PayDebt Degradation ────────────────────────────────────────

    function test_payDebt_graceful_payReverts_returns0() public {
        // PayDebt with no target (address(0)) returns 0 immediately
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 50,
            outputToken: address(0),
            target: address(0) // returns 0 immediately
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        // PayDebt returns 0, so all distributable goes to remainder -> recipient
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "All to recipient when PayDebt returns 0");
    }

    function test_payDebt_graceful_zeroBalance_remainderToRecipient() public {
        // PayDebt fails -> 0 consumed -> tokens go to remainder -> recipient
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(0) // no target -> returns 0
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "Remainder to recipient");
    }

    // ====================================================================
    // Section 20: Access Control
    // ====================================================================

    function test_access_processRewards_onlyAuthorizedCaller() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(_tokenId, rewards, _noSwap(), 0);
    }

    function test_access_processRewards_authorizedCaller() public {
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // Should not revert
        _processRewards(rewards, 0);
    }

    function test_access_swapToRewardsToken_onlyAuthorizedCaller() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        rewardsProcessingFacet.swapToRewardsToken(SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(0),
            swapData: "",
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: 0
        }));
    }

    // ====================================================================
    // Bug Fix Verification Tests
    // ====================================================================

    // ── Bug Fix 1: LoanConfig setters reject zero values ───────────────

    function test_bugfix1_setLenderPremium_rejectsZero() public {
        // The setter now requires lenderPremium > 0 to prevent _payLenderPremium
        // from calling depositRewards(0) which reverts on the loan contract.
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert("Lender premium must be > 0");
        _loanConfig.setLenderPremium(0);
    }

    function test_bugfix1_setTreasuryFee_rejectsZero() public {
        // The setter now requires treasuryFee > 0.
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert("Treasury fee must be > 0");
        _loanConfig.setTreasuryFee(0);
    }

    function test_bugfix1_setZeroBalanceFee_rejectsZero() public {
        // The setter now requires zeroBalanceFee > 0.
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert("Zero balance fee must be > 0");
        _loanConfig.setZeroBalanceFee(0);
    }

    // ── Bug Fix 2: Both blacklisted → tokens flow to default recipient ──

    function test_bugfix2_payBalance_bothBlacklisted_tokensFlowToRecipient() public {
        // Setup: Deploy wallet factory (salt=0) and wallet account
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory walletFactory,) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        address walletAccount = walletFactory.createAccount(_user);

        // Deploy blacklistable token as rewards token
        MockBlacklistableERC20 blacklistToken = new MockBlacklistableERC20("BLUSDC", "BLUSDC", 6);
        _useTokenAsRewardsAsset(address(blacklistToken));

        // Blacklist both the PayBalance target AND the wallet account
        address blacklistedTarget = address(0xB1AC1);
        blacklistToken.setBlacklisted(blacklistedTarget, true);
        blacklistToken.setBlacklisted(walletAccount, true);

        // Set up zero balance distribution: 100% PayBalance to blacklisted target
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: blacklistedTarget
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e6;
        deal(address(blacklistToken), _portfolioAccount, rewards);

        // Process rewards (no debt = zero balance path)
        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        // BUG FIX 2: _executeDistributionEntry returns 0 when both target and wallet
        // are blacklisted, so tokens stay in `remaining` and flow to default recipient.
        assertEq(blacklistToken.balanceOf(blacklistedTarget), 0, "Blacklisted target gets nothing");
        assertEq(blacklistToken.balanceOf(walletAccount), 0, "Blacklisted wallet gets nothing");
        assertEq(blacklistToken.balanceOf(recipient), distributable, "Default recipient receives tokens as remainder");
        assertEq(blacklistToken.balanceOf(_portfolioAccount), 0, "No tokens stuck in portfolio");
    }

    function test_bugfix2_payToRecipient_bothBlacklisted_tokensFlowToRecipient() public {
        // Setup: Deploy wallet factory (salt=0) and wallet account
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory walletFactory,) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        address walletAccount = walletFactory.createAccount(_user);

        // Deploy blacklistable token as rewards token
        MockBlacklistableERC20 blacklistToken = new MockBlacklistableERC20("BLUSDC2", "BLUSDC2", 6);
        _useTokenAsRewardsAsset(address(blacklistToken));

        // Blacklist both the PayToRecipient target AND the wallet account
        address blacklistedTarget = address(0xB1AC2);
        blacklistToken.setBlacklisted(blacklistedTarget, true);
        blacklistToken.setBlacklisted(walletAccount, true);

        // Set up zero balance distribution: 100% PayToRecipient (same token) to blacklisted target
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0), // same token, no swap
            target: blacklistedTarget
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e6;
        deal(address(blacklistToken), _portfolioAccount, rewards);

        // Process rewards (no debt = zero balance path)
        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        // BUG FIX 2: _payToRecipientWithToken returns 0 when both recipient and wallet
        // are blacklisted, so tokens stay in `remaining` and flow to default recipient.
        assertEq(blacklistToken.balanceOf(blacklistedTarget), 0, "Blacklisted target gets nothing");
        assertEq(blacklistToken.balanceOf(walletAccount), 0, "Blacklisted wallet gets nothing");
        assertEq(blacklistToken.balanceOf(recipient), distributable, "Default recipient receives tokens as remainder");
        assertEq(blacklistToken.balanceOf(_portfolioAccount), 0, "No tokens stuck in portfolio");
    }

    // ── Bug Fix 3: Zero balance remainder uses trySafeTransfer ──────────

    function test_bugfix3_zeroBalanceRemainder_blacklistedRecipient_noRevert() public {
        // Setup: Deploy wallet factory (salt=0) and wallet account
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory walletFactory,) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        address walletAccount = walletFactory.createAccount(_user);

        // Deploy blacklistable token as rewards token
        MockBlacklistableERC20 blacklistToken = new MockBlacklistableERC20("BLUSDC3", "BLUSDC3", 6);
        _useTokenAsRewardsAsset(address(blacklistToken));

        // Set recipient to blacklisted address
        address blacklistedRecipient = address(0xB1AC3);

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, blacklistedRecipient);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        blacklistToken.setBlacklisted(blacklistedRecipient, true);

        // No zero balance distribution configured -> all goes to remainder -> recipient
        uint256 rewards = 500e6;
        deal(address(blacklistToken), _portfolioAccount, rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 remainder = rewards - fee;

        // BUG FIX 3: Previously this would hard revert because safeTransfer was used.
        // Now trySafeTransfer is used with fallback to wallet account.
        // Expect TransferFailed event
        vm.expectEmit(true, true, true, true);
        emit TransferFailed(
            _currentEpochStart(),
            _tokenId,
            remainder,
            blacklistedRecipient,
            address(blacklistToken),
            _portfolioFactory.ownerOf(_portfolioAccount)
        );

        _processRewards(rewards, 0);

        // Tokens should go to wallet account (fallback)
        assertEq(blacklistToken.balanceOf(blacklistedRecipient), 0, "Blacklisted recipient gets nothing");
        assertEq(blacklistToken.balanceOf(walletAccount), remainder, "Wallet account receives remainder via fallback");
    }

    function test_bugfix3_zeroBalanceRemainder_bothBlacklisted_tokensStayInPortfolio() public {
        // Setup: Deploy wallet factory (salt=0) and wallet account
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory walletFactory,) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        address walletAccount = walletFactory.createAccount(_user);

        // Deploy blacklistable token as rewards token
        MockBlacklistableERC20 blacklistToken = new MockBlacklistableERC20("BLUSDC4", "BLUSDC4", 6);
        _useTokenAsRewardsAsset(address(blacklistToken));

        // Set recipient to blacklisted address
        address blacklistedRecipient = address(0xB1AC4);

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, blacklistedRecipient);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        // Blacklist BOTH the recipient AND the wallet account
        blacklistToken.setBlacklisted(blacklistedRecipient, true);
        blacklistToken.setBlacklisted(walletAccount, true);

        // No zero balance distribution configured -> all goes to remainder -> recipient
        uint256 rewards = 500e6;
        deal(address(blacklistToken), _portfolioAccount, rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 remainder = rewards - fee;

        // BUG FIX 3: processRewards does NOT revert even when both are blacklisted.
        // trySafeTransfer to recipient fails, _sendToWalletAccount also fails (wallet blacklisted).
        // Tokens stay in portfolio account as a last resort.
        _processRewards(rewards, 0);

        assertEq(blacklistToken.balanceOf(blacklistedRecipient), 0, "Blacklisted recipient gets nothing");
        assertEq(blacklistToken.balanceOf(walletAccount), 0, "Blacklisted wallet gets nothing");
        assertEq(blacklistToken.balanceOf(_portfolioAccount), remainder, "Tokens stay in portfolio as last resort");
    }
}
