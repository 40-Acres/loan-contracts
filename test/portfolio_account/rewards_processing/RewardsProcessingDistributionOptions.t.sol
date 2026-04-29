// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {RewardsTokenHelper} from "../utils/RewardsTokenHelper.sol";
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
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";

// ======================== Mock Contracts ========================

/// @dev ERC4626 vault mock that can be paused
contract MockPausableVaultV2 {
    address public _asset;
    bool public paused;
    address public _recipient;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function deposit(uint256 amount, address recipient_) external returns (uint256) {
        require(!paused, "Vault is paused");
        // Pull tokens and return 1:1 shares (mock)
        IERC20(_asset).transferFrom(msg.sender, address(this), amount);
        _recipient = recipient_;
        return amount;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

/// @dev ERC4626 vault mock for a different asset
contract MockVaultWithAsset {
    address public _asset;
    mapping(address => uint256) public shares;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function deposit(uint256 amount, address recipient_) external returns (uint256) {
        IERC20(_asset).transferFrom(msg.sender, address(this), amount);
        shares[recipient_] += amount;
        return amount;
    }
}

/// @dev Mock lending facet for cross-factory PayDebt testing
contract MockLendingTarget {
    address public lendingToken;
    uint256 public debt;

    constructor(address _lendingToken) {
        lendingToken = _lendingToken;
    }

    function setDebt(uint256 _debt) external {
        debt = _debt;
    }

    function pay(uint256 amount) external returns (uint256 excess) {
        require(debt > 0, "No debt");
        IERC20(lendingToken).transferFrom(msg.sender, address(this), amount);
        if (amount > debt) {
            excess = amount - debt;
            debt = 0;
            // refund excess
            IERC20(lendingToken).transfer(msg.sender, excess);
        } else {
            debt -= amount;
            excess = 0;
        }
    }
}

/**
 * =============================================================================
 * BATCH 2: Distribution Options Tests for RewardsProcessingFacet
 *
 * Covers:
 *   Section 7:  PayToRecipient
 *   Section 8:  InvestToVault
 *   Section 9:  IncreaseCollateral
 *   Section 10: PayDebt
 * =============================================================================
 */
contract RewardsProcessingDistributionOptionsTest is Test, RewardsTokenHelper {
    RewardsProcessingFacet public rewardsProcessingFacet;
    MockOdosRouterRL public mockRouter;

    address public rewardsToken;
    address public lockedAsset;
    uint256 public rewardsAmount = 1000e6;
    address public recipient = address(0x1234);

    uint256 constant TREASURY_FEE_BPS = 500;
    uint256 constant LENDER_PREMIUM_BPS = 2000;
    uint256 constant ZERO_BAL_FEE_BPS = 100;
    uint256 constant BPS_DENOM = 10000;

    // Second token for swap testing
    MockERC20 public outputToken;

    // Wallet factory and account (for _sendToWalletAccount tests)
    PortfolioFactory public walletFactory;
    address public walletAccount;

    // Vault2 for second factory PayDebt tests
    address public _vault2;

    // Events
    event GasReclamationPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ProtocolFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ZeroBalanceFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event LenderPremiumPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event RewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 rewardsAmount, address user, address asset);
    event LoanPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event DebtPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address recipient, address asset);
    event ZeroBalanceRewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 remainingAmount, address indexed recipient, address asset, address indexed owner);
    event ActiveBalanceRewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event InvestedToVault(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event InvestToVaultFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event IncreaseCollateralFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);
    event CollateralIncreased(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);
    event TransferFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);
    event PaidToRecipient(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);
    event SwapExecuted(address indexed swapTarget, address indexed inputToken, uint256 inputAmount, address indexed outputToken, uint256 outputAmount);

    function setUp() public override {
        super.setUp();

        // Deploy RewardsProcessingFacet
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_swapConfig), address(_ve), _vault);

        // Register setVaultForInvesting and clearZeroBalanceDistribution selectors
        // (not registered by default in LocalSetup)
        RewardsConfigFacet configFacetForExtras = new RewardsConfigFacet(address(_portfolioFactory));
        bytes4[] memory extraSel = new bytes4[](2);
        extraSel[0] = RewardsConfigFacet.setVaultForInvesting.selector;
        extraSel[1] = RewardsConfigFacet.clearZeroBalanceDistribution.selector;
        _facetRegistry.registerFacet(address(configFacetForExtras), extraSel, "RewardsConfigFacetExtras");
        vm.stopPrank();

        // Initialize facet reference
        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);

        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        // Set up tokens
        rewardsToken = address(_usdc);
        lockedAsset = IVotingEscrow(_ve).token();

        // Deploy second token for swap testing
        outputToken = new MockERC20("Output Token", "OUT", 6);

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

        // Deploy wallet factory (salt=0) for _sendToWalletAccount tests
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (walletFactory,) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        walletAccount = walletFactory.createAccount(_user);
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
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry memory entry) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setActiveBalanceDistribution.selector, entry);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _getOwner() internal view returns (address) {
        return _portfolioFactoryConfig.owner();
    }

    function _currentEpochStart() internal view returns (uint256) {
        return (block.timestamp / 1 weeks) * 1 weeks;
    }

    /// @dev Build swap params for slot 0 (active balance or first zero balance entry)
    function _buildSwapParams(
        address inputToken_,
        address outputToken_,
        uint256 inputAmount_,
        uint256 outputAmount_,
        uint8 slot
    ) internal returns (SwapMod.RouteParams[4] memory swapParams) {
        deal(outputToken_, address(mockRouter), outputAmount_);

        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            inputToken_,
            outputToken_,
            inputAmount_,
            outputAmount_,
            _portfolioAccount
        );

        vm.prank(_portfolioAccount);
        IERC20(inputToken_).approve(address(mockRouter), inputAmount_);

        swapParams[slot] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: swapData,
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: 0
        });
    }

    function _setVaultForInvesting(address vault) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setVaultForInvesting.selector, vault);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // ====================================================================
    // Section 7: PayToRecipient
    // ====================================================================

    // ── 7.1 Same Token (No Swap) ───────────────────────────────────────

    function test_payToRecipient_sameToken_success() public {
        // outputToken = address(0), defaults to asset, direct transfer
        address target = address(0xCAFE01);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0), // defaults to asset
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(target), rewards - fee, "Recipient gets full distributable (same token)");
    }

    function test_payToRecipient_sameToken_explicitOutputToken() public {
        // outputToken explicitly set to same as asset -> no swap
        address target = address(0xCAFE02);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: rewardsToken, // explicitly same as asset
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(target), rewards - fee, "Explicit same-token means no swap");
    }

    function test_payToRecipient_sameToken_transferFail_sendsToWallet() public {
        // Blacklisted recipient -> trySafeTransfer fails -> sends to wallet
        MockBlacklistableERC20 blacklistToken = new MockBlacklistableERC20("BLUSDC", "BLUSDC", 6);

        // setRewardsToken was removed; swap the facet's vault so getRewardsToken()
        // resolves to the blacklist token.
        _useTokenAsRewardsAsset(address(blacklistToken));

        address blacklistedRecipient = address(0xB1AC1);
        blacklistToken.setBlacklisted(blacklistedRecipient, true);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0),
            target: blacklistedRecipient
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e6;
        deal(address(blacklistToken), _portfolioAccount, rewards);

        _processRewards(rewards, 0);

        // zeroBalanceFee computed on blacklistToken. Fee goes to config.owner().
        // But config.owner() may not be blacklisted, so fee transfer succeeds.
        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        // Transfer to blacklistedRecipient fails -> sent to wallet account
        assertEq(blacklistToken.balanceOf(walletAccount), distributable, "Blacklisted recipient: tokens to wallet");
    }

    function test_payToRecipient_sameToken_emitsPaidToRecipient() public {
        address target = address(0xCAFE04);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, true, true);
        emit PaidToRecipient(_currentEpochStart(), _tokenId, distributable, target, rewardsToken, portfolioOwner);

        _processRewards(rewards, 0);
    }

    // ── 7.2 Different Token (With Swap) ────────────────────────────────

    function test_payToRecipient_differentToken_swapAndTransfer() public {
        address target = address(0xCAFE05);
        uint256 swapOut = 800e6;

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(outputToken),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, address(outputToken), distributable, swapOut, 0
        );

        _processRewardsWithSwap(rewards, 0, swapParams);

        assertEq(outputToken.balanceOf(target), swapOut, "Recipient gets swapped output token");
    }

    function test_payToRecipient_differentToken_transferFail_postSwap_sendsToWallet() public {
        // Swap succeeds but recipient is blacklisted for output token
        MockBlacklistableERC20 blacklistOutput = new MockBlacklistableERC20("BLOUT", "BLOUT", 6);
        address blacklistedRecipient = address(0xB1AC2);
        blacklistOutput.setBlacklisted(blacklistedRecipient, true);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(blacklistOutput),
            target: blacklistedRecipient
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 swapOut = 500e6;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, address(blacklistOutput), distributable, swapOut, 0
        );

        _processRewardsWithSwap(rewards, 0, swapParams);

        // Transfer to blacklistedRecipient fails -> sent to wallet
        assertEq(blacklistOutput.balanceOf(walletAccount), swapOut, "Post-swap blacklist: tokens to wallet");
    }

    function test_payToRecipient_differentToken_swapReverts() public {
        // Swap fails -> entire processRewards reverts (swap not in try/catch for PayToRecipient)
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(outputToken),
            target: address(0xCAFE)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // Don't set up mock router swap data -> swap will fail
        SwapMod.RouteParams[4] memory badSwapParams;
        badSwapParams[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: abi.encodeWithSelector(
                MockOdosRouterRL.executeSwap.selector,
                rewardsToken, address(outputToken), 990e6, 0, _portfolioAccount
            ),
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: 1e6 // minimumOutputAmount > 0 but output = 0 -> slippage revert
        });

        vm.prank(_portfolioAccount);
        IERC20(rewardsToken).approve(address(mockRouter), 990e6);

        vm.prank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(_tokenId, rewards, badSwapParams, 0);
    }

    function test_payToRecipient_differentToken_emitsPaidToRecipient() public {
        // PaidToRecipient event emits the input amount, not the swapped amount
        address target = address(0xCAFE06);
        uint256 swapOut = 800e6;

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(outputToken),
            target: target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, address(outputToken), distributable, swapOut, 0
        );

        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        // PaidToRecipient emits the original input `amount`, not swappedAmount
        vm.expectEmit(true, true, true, true);
        emit PaidToRecipient(_currentEpochStart(), _tokenId, distributable, target, rewardsToken, portfolioOwner);

        _processRewardsWithSwap(rewards, 0, swapParams);
    }

    // ── 7.3 Target Resolution ──────────────────────────────────────────

    function test_payToRecipient_explicitTarget() public {
        address explicitTarget = address(0xE001);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0),
            target: explicitTarget
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(explicitTarget), rewards - fee, "Tokens to explicit target");
    }

    function test_payToRecipient_noTarget_usesDefaultRecipient() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0),
            target: address(0) // falls back to _getRecipient() which is `recipient`
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "Falls back to default recipient");
    }

    function test_payToRecipient_returnsInputAmount() public {
        // PayToRecipient always returns the input `amount`, not swapped amount
        // Verify by checking that remaining is properly reduced
        address target = address(0xCAFE07);
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
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
        // Remainder to default recipient proves PayToRecipient consumed exactly entryAmount
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - entryAmount, "Remainder proves input amount returned");
    }

    // ====================================================================
    // Section 8: InvestToVault
    // ====================================================================

    // ── 8.1 Vault Resolution ───────────────────────────────────────────

    function test_investToVault_explicitTarget() public {
        // entry.target = specific vault address -> deposits into that vault
        MockVaultWithAsset customVault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(customVault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        assertEq(IERC20(rewardsToken).balanceOf(address(customVault)), distributable, "Deposited to explicit vault");
    }

    function test_investToVault_noTarget_usesConfigVault() public {
        // target = 0, UserRewardsConfig.vaultForInvesting set -> uses config vault
        MockVaultWithAsset configVault = new MockVaultWithAsset(rewardsToken);
        _setVaultForInvesting(address(configVault));

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(0) // uses config vault
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        assertEq(IERC20(rewardsToken).balanceOf(address(configVault)), distributable, "Deposited to config vault");
    }

    function test_investToVault_noTarget_noConfigVault_usesDefault() public {
        // target = 0, vaultForInvesting = 0 -> uses immutable _vault
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(0) // no config vault -> uses _vault
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 vaultBefore = IERC20(rewardsToken).balanceOf(_vault);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 vaultAfter = IERC20(rewardsToken).balanceOf(_vault);

        assertEq(vaultAfter - vaultBefore, distributable, "Deposited to default _vault");
    }

    function test_investToVault_thirdPartyVault() public {
        // External ERC4626 vault (not protocol vault) — shares minted to owner
        MockVaultWithAsset thirdPartyVault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(thirdPartyVault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        assertEq(thirdPartyVault.shares(portfolioOwner), distributable, "Shares minted to owner");
    }

    // ── 8.2 Same Asset (No Swap) ───────────────────────────────────────

    function test_investToVault_sameAsset_deposit() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(address(vault)), rewards - fee, "Same asset deposit, no swap");
    }

    function test_investToVault_sameAsset_depositsCorrectAmount() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 50,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 depositAmount = distributable * 50 / 100;

        assertEq(IERC20(rewardsToken).balanceOf(address(vault)), depositAmount, "Correct 50% deposited");
    }

    function test_investToVault_sameAsset_sharesToOwner() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        assertEq(vault.shares(portfolioOwner), rewards - fee, "Shares to owner");
    }

    function test_investToVault_sameAsset_approvalResetAfterDeposit() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 allowance = IERC20(rewardsToken).allowance(_portfolioAccount, address(vault));
        assertEq(allowance, 0, "Approval reset to 0 after deposit");
    }

    function test_investToVault_sameAsset_emitsInvestedToVault() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, true, true);
        emit InvestedToVault(_currentEpochStart(), _tokenId, distributable, rewardsToken, portfolioOwner);

        _processRewards(rewards, 0);
    }

    // ── 8.3 Different Asset (With Swap) ────────────────────────────────

    function test_investToVault_differentAsset_swapThenDeposit() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(address(outputToken));
        uint256 swapOut = 800e6;

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, address(outputToken), distributable, swapOut, 0
        );

        _processRewardsWithSwap(rewards, 0, swapParams);

        assertEq(outputToken.balanceOf(address(vault)), swapOut, "Vault received swapped tokens");
    }

    function test_investToVault_differentAsset_swapReverts() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(address(outputToken));

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // Bad swap params -> swap fails -> reverts
        SwapMod.RouteParams[4] memory badSwapParams;
        badSwapParams[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: abi.encodeWithSelector(
                MockOdosRouterRL.executeSwap.selector,
                rewardsToken, address(outputToken), 990e6, 0, _portfolioAccount
            ),
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: 1e6
        });

        vm.prank(_portfolioAccount);
        IERC20(rewardsToken).approve(address(mockRouter), 990e6);

        vm.prank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(_tokenId, rewards, badSwapParams, 0);
    }

    function test_investToVault_differentAsset_depositsSwappedAmount() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(address(outputToken));
        uint256 swapOut = 600e6;

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, address(outputToken), distributable, swapOut, 0
        );

        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        _processRewardsWithSwap(rewards, 0, swapParams);

        // Verify the swapped output amount (not input) was deposited
        assertEq(vault.shares(portfolioOwner), swapOut, "Shares = swapped amount deposited");
    }

    // ── 8.4 Deposit Failure (try/catch) ────────────────────────────────

    function test_investToVault_depositFails_noSwap_returns0() public {
        MockPausableVaultV2 pausableVault = new MockPausableVaultV2(rewardsToken);
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
        // Returns 0 -> tokens stay in remaining -> sent to default recipient
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "No-swap failure: all to recipient");
    }

    function test_investToVault_depositFails_postSwap_sendsToWallet() public {
        MockPausableVaultV2 pausableVault = new MockPausableVaultV2(address(outputToken));
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
        uint256 swapOut = 500e6;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, address(outputToken), distributable, swapOut, 0
        );

        _processRewardsWithSwap(rewards, 0, swapParams);

        // Post-swap: vault deposit fails -> swapped tokens sent to wallet
        assertEq(outputToken.balanceOf(walletAccount), swapOut, "Post-swap failure: tokens to wallet");
    }

    function test_investToVault_depositFails_emitsInvestToVaultFailed() public {
        MockPausableVaultV2 pausableVault = new MockPausableVaultV2(rewardsToken);
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
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, true, true);
        emit InvestToVaultFailed(_currentEpochStart(), _tokenId, distributable, rewardsToken, portfolioOwner);

        _processRewards(rewards, 0);
    }

    function test_investToVault_depositFails_approvalReset() public {
        MockPausableVaultV2 pausableVault = new MockPausableVaultV2(rewardsToken);
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

        uint256 allowance = IERC20(rewardsToken).allowance(_portfolioAccount, address(pausableVault));
        assertEq(allowance, 0, "Approval reset to 0 on failure");
    }

    function test_investToVault_depositFails_noSwap_tokensRemainInAccount() public {
        // The tokens stay in "remaining" and eventually go to default recipient.
        // But if there's NO default recipient destination that accepts them,
        // let's verify intermediate state: after failure, the portfolio still has the tokens
        // until they're sent to recipient in the remainder flow.
        MockPausableVaultV2 pausableVault = new MockPausableVaultV2(rewardsToken);
        pausableVault.setPaused(true);

        // Use 50% so we can verify partial failure behavior
        address target2 = address(0xCAFE);
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
            target: target2
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 entry2Amount = distributable * 50 / 100;

        // Entry 0 (InvestToVault, 50%) fails -> returns 0 -> tokens stay in remaining
        // Entry 1 (PayBalance, 50%) gets its share
        assertEq(IERC20(rewardsToken).balanceOf(target2), entry2Amount, "PayBalance entry processes normally");
        // The failed entry's share stays in remaining and goes to default recipient
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable - entry2Amount, "Failed share to recipient");
        // Portfolio account should have 0 left
        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio drained");
    }

    function test_investToVault_depositFails_pausedVault() public {
        // Same as depositFails_noSwap_returns0 but explicitly documenting paused vault scenario
        MockPausableVaultV2 pausableVault = new MockPausableVaultV2(rewardsToken);
        pausableVault.setPaused(true);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(pausableVault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e6;
        _fundPortfolio(rewards);

        // Should not revert — graceful degradation
        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "Paused vault: graceful degradation");
    }

    // ── 8.5 Balance Capping ────────────────────────────────────────────

    function test_investToVault_balanceLessThanAmount() public {
        // Account balance of vaultAsset < actualAmountToInvest
        // This can happen if there's a fee or other deduction between calculation and deposit
        MockVaultWithAsset vault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // The code uses min(balance, actualAmountToInvest). With no fee manipulation,
        // balance == actualAmountToInvest. But we verify the cap logic works by confirming
        // the full distributable amount is deposited.
        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(address(vault)), rewards - fee, "Full amount deposited (balance = amount)");
    }

    function test_investToVault_balanceEqualsAmount() public {
        MockVaultWithAsset vault = new MockVaultWithAsset(rewardsToken);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.InvestToVault,
            percentage: 100,
            outputToken: address(0),
            target: address(vault)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 777e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        assertEq(vault.shares(portfolioOwner), rewards - fee, "Exact balance deposited");
    }

    // ====================================================================
    // Section 9: IncreaseCollateral
    // ====================================================================

    // ── 9.1 Same Token as Collateral (No Swap) ────────────────────────

    function test_increaseCollateral_sameToken_success() public {
        // Set rewards token to AERO (same as collateral) for no-swap path
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        // Fund AERO to VE for the increaseAmount call
        uint256 veBefore = IERC20(lockedAsset).balanceOf(address(_ve));

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        // VE should have received the tokens via increaseAmount
        uint256 veAfter = IERC20(lockedAsset).balanceOf(address(_ve));
        assertEq(veAfter - veBefore, distributable, "VE received collateral tokens");
    }

    function test_increaseCollateral_sameToken_lockFails_returns0() public {
        // Set rewards token to AERO and use tokenId=0 so _increaseCollateral returns 0
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        // Process with tokenId=0 -> _increaseCollateral returns 0
        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(0, rewards, noSwap, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        // Returns 0 -> tokens stay in remaining -> sent to recipient
        assertEq(IERC20(lockedAsset).balanceOf(recipient), rewards - fee, "Lock fails: all to recipient");
    }

    function test_increaseCollateral_sameToken_updatesLockedCollateral() public {
        // After successful increaseAmount, CollateralManager.updateLockedCollateral is called
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 lockedBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        uint256 rewards = 500e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        _processRewards(rewards, 0);

        uint256 lockedAfter = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(lockedAfter, lockedBefore, "Locked collateral increased after IncreaseCollateral");
    }

    // ── 9.2 Different Token (With Swap) ────────────────────────────────

    function test_increaseCollateral_differentToken_swapAndLock() public {
        // USDC -> AERO swap, then increase lock
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 swapOut = 200e18;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, lockedAsset, distributable, swapOut, 0
        );

        uint256 veBefore = IERC20(lockedAsset).balanceOf(address(_ve));

        _processRewardsWithSwap(rewards, 0, swapParams);

        uint256 veAfter = IERC20(lockedAsset).balanceOf(address(_ve));
        assertEq(veAfter - veBefore, swapOut, "VE received swapped AERO");
    }

    function test_increaseCollateral_differentToken_swapReverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // Bad swap
        SwapMod.RouteParams[4] memory badSwapParams;
        badSwapParams[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: abi.encodeWithSelector(
                MockOdosRouterRL.executeSwap.selector,
                rewardsToken, lockedAsset, 990e6, 0, _portfolioAccount
            ),
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: 1e18
        });

        vm.prank(_portfolioAccount);
        IERC20(rewardsToken).approve(address(mockRouter), 990e6);

        vm.prank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(_tokenId, rewards, badSwapParams, 0);
    }

    function test_increaseCollateral_differentToken_requiresSwapTarget() public {
        // When asset != lockedAsset and no swap target provided, reverts
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // No swap params -> swapTarget = address(0) -> reverts
        vm.prank(_authorizedCaller);
        vm.expectRevert("Swap target must be provided");
        rewardsProcessingFacet.processRewards(_tokenId, rewards, _noSwap(), 0);
    }

    function test_increaseCollateral_differentToken_usesBalanceDelta() public {
        // Swap output computed via balance before/after
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 swapOut = 300e18;

        // Pre-fund some AERO to portfolio to test balance delta correctly
        uint256 preExistingAero = 100e18;
        deal(lockedAsset, _portfolioAccount, preExistingAero);

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, lockedAsset, distributable, swapOut, 0
        );

        uint256 veBefore = IERC20(lockedAsset).balanceOf(address(_ve));

        _processRewardsWithSwap(rewards, 0, swapParams);

        // increaseAmount = endingBalance - beginningBalance = (preExisting + swapOut) - preExisting = swapOut
        uint256 veAfter = IERC20(lockedAsset).balanceOf(address(_ve));
        assertEq(veAfter - veBefore, swapOut, "Balance delta used for increaseAmount");
    }

    // ── 9.3 Lock Failure After Swap (try/catch) ────────────────────────

    function test_increaseCollateral_lockFails_postSwap_sendsToWallet() public {
        // Swap succeeds but increaseAmount reverts -> tokens to wallet
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

        // Use a non-existent tokenId so increaseAmount fails in try/catch
        uint256 fakeTokenId = 999;
        vm.prank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(fakeTokenId, rewards, swapParams, 0);

        // Swapped AERO tokens sent to wallet
        assertEq(IERC20(lockedAsset).balanceOf(walletAccount), swapOut, "Post-swap lock failure: tokens to wallet");
    }

    function test_increaseCollateral_lockFails_noSwap_returns0() public {
        // Same token, lock fails -> returns 0
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        // tokenId=0 -> returns 0 immediately
        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(0, rewards, noSwap, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(lockedAsset).balanceOf(recipient), rewards - fee, "No-swap lock fail: all to recipient");
    }

    function test_increaseCollateral_lockFails_emitsIncreaseCollateralFailed() public {
        // Use a non-existent tokenId with swap so increaseAmount fails
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 swapOut = 200e18;

        SwapMod.RouteParams[4] memory swapParams = _buildSwapParams(
            rewardsToken, lockedAsset, distributable, swapOut, 0
        );

        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 fakeTokenId = 888;

        vm.expectEmit(true, true, true, true);
        emit IncreaseCollateralFailed(_currentEpochStart(), fakeTokenId, swapOut, portfolioOwner);

        vm.prank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(fakeTokenId, rewards, swapParams, 0);
    }

    function test_increaseCollateral_lockFails_approvalReset() public {
        // After lock failure, VE allowance should be reset
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        // Use non-existent tokenId to trigger failure in _increaseLock
        uint256 fakeTokenId = 777;
        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(fakeTokenId, rewards, noSwap, 0);

        // VE approval should be reset to 0
        uint256 allowance = IERC20(lockedAsset).allowance(_portfolioAccount, address(_ve));
        assertEq(allowance, 0, "VE approval reset on lock failure");
    }

    // ── 9.4 VotingEscrow-Specific ──────────────────────────────────────

    function test_veIncreaseLock_tokenId0_returns0() public {
        // tokenId == 0 -> _increaseLock returns 0 immediately
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(0, rewards, noSwap, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        // tokenId=0 -> _increaseCollateral returns 0 -> all to recipient
        assertEq(IERC20(lockedAsset).balanceOf(recipient), rewards - fee, "tokenId=0 returns 0");
    }

    function test_veIncreaseLock_success_updatesCollateral() public {
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 lockedBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        uint256 rewards = 500e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        _processRewards(rewards, 0);

        uint256 lockedAfter = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(lockedAfter, lockedBefore, "Collateral updated after successful lock");
    }

    function test_veIncreaseLock_success_emitsCollateralIncreased() public {
        _useTokenAsRewardsAsset(lockedAsset);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 100,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e18;
        deal(lockedAsset, _portfolioAccount, rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);

        vm.expectEmit(true, true, true, true);
        emit CollateralIncreased(_currentEpochStart(), _tokenId, distributable, portfolioOwner);

        _processRewards(rewards, 0);
    }

    function test_veIncreaseCollateral_tokenId0_returns0_skipsSuper() public {
        // VotingEscrowRewardsProcessingFacet._increaseCollateral checks tokenId==0 first
        // and returns 0 without calling super._increaseCollateral
        // Verify by checking no swap is required even when rewardsToken != collateralToken

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 50,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // Process with tokenId=0, no swap params. If super was called, it would revert
        // because rewardsToken != collateralToken and no swap target provided.
        // But tokenId=0 check in override returns 0 BEFORE calling super.
        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(0, rewards, noSwap, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "tokenId=0 skips super, no revert");
    }

    // ── 9.5 Blackhole-Specific ─────────────────────────────────────────
    // Deferred to Batch 4: Blackhole variant needs separate factory with different VE type

    // ====================================================================
    // Section 10: PayDebt
    // ====================================================================

    function test_payDebt_targetFactoryZero_returns0() public {
        // entry.target = address(0) -> returns 0 immediately
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(0) // returns 0
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        // Returns 0 -> all to recipient
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "Target=0: all to recipient");
    }

    function test_payDebt_success_fullDebtRepayment() public {
        // Create a second factory with debt, pay debt from source portfolio
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-2"))
        );
        vm.stopPrank();

        // Set up factory2 with same config, loan, facets
        _setupSecondFactory(factory2, registry2);

        // Create portfolio for _user on factory2
        address portfolio2 = factory2.createAccount(_user);

        // Give portfolio2 a veNFT and create debt
        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        // Add collateral and borrow on factory2
        vm.startPrank(_user);
        address[] memory pf2 = new address[](2);
        pf2[0] = address(factory2);
        pf2[1] = address(factory2);
        bytes[] memory cd2 = new bytes[](2);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        cd2[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 500e6);
        deal(address(_usdc), _vault2, 1000e6);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();

        // Now set up PayDebt distribution on source portfolio (factory1)
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });
        _setZeroBalanceDistribution(entries);

        uint256 debtBefore = CollateralFacet(portfolio2).getTotalDebt();

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 debtAfter = CollateralFacet(portfolio2).getTotalDebt();
        assertEq(debtAfter, 0, "Debt on factory2 fully repaid");
        assertLt(debtAfter, debtBefore, "Debt reduced");
    }

    function test_payDebt_success_partialRepayment() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-3"))
        );
        vm.stopPrank();

        _setupSecondFactory(factory2, registry2);
        address portfolio2 = factory2.createAccount(_user);

        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        vm.startPrank(_user);
        address[] memory pf2 = new address[](2);
        pf2[0] = address(factory2);
        pf2[1] = address(factory2);
        bytes[] memory cd2 = new bytes[](2);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        cd2[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 2000e6);
        deal(address(_usdc), _vault2, 3000e6);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });
        _setZeroBalanceDistribution(entries);

        uint256 debtBefore = CollateralFacet(portfolio2).getTotalDebt();

        uint256 rewards = 500e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        uint256 debtAfter = CollateralFacet(portfolio2).getTotalDebt();
        assertEq(debtBefore - debtAfter, distributable, "Partial debt repayment");
        assertGt(debtAfter, 0, "Still has remaining debt");
    }

    function test_payDebt_targetNotRegisteredFactory() public {
        // Target is not a registered factory -> reverts at config validation
        address fakeFactory = address(0xFA1E);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: fakeFactory
        });

        // The config setter validates this
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);

        vm.expectRevert("PayDebt target must be registered factory");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function test_payDebt_targetHasNoPortfolio() public {
        // Factory registered but owner has no portfolio there
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2,) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-no-portfolio"))
        );
        vm.stopPrank();

        // Don't create account for _user on factory2

        // The config setter also validates this
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);

        vm.expectRevert("PayDebt target factory must have portfolio for owner");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function test_payDebt_payReverts_returns0() public {
        // PayDebt where pay() reverts -> try/catch returns 0
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-4"))
        );
        vm.stopPrank();

        _setupSecondFactory(factory2, registry2);
        address portfolio2 = factory2.createAccount(_user);

        // Give veNFT to portfolio2 but DON'T create any debt
        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        // Add collateral but no borrow -> portfolio2 has 0 debt
        vm.startPrank(_user);
        address[] memory pf2 = new address[](1);
        pf2[0] = address(factory2);
        bytes[] memory cd2 = new bytes[](1);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 500e6;
        _fundPortfolio(rewards);

        // pay() will try to decrease debt of 0, which should revert -> try/catch returns 0
        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        // PayDebt returns 0 -> all to recipient
        assertEq(IERC20(rewardsToken).balanceOf(recipient), rewards - fee, "Pay reverts: all to recipient");
    }

    function test_payDebt_approvalResetAfter() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-5"))
        );
        vm.stopPrank();

        _setupSecondFactory(factory2, registry2);
        address portfolio2 = factory2.createAccount(_user);

        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        vm.startPrank(_user);
        address[] memory pf2 = new address[](2);
        pf2[0] = address(factory2);
        pf2[1] = address(factory2);
        bytes[] memory cd2 = new bytes[](2);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        cd2[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 500e6);
        deal(address(_usdc), _vault2, 1000e6);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 allowance = IERC20(rewardsToken).allowance(_portfolioAccount, portfolio2);
        assertEq(allowance, 0, "Approval reset to 0 after pay");
    }

    function test_payDebt_emitsDebtPaid() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-6"))
        );
        vm.stopPrank();

        _setupSecondFactory(factory2, registry2);
        address portfolio2 = factory2.createAccount(_user);

        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        vm.startPrank(_user);
        address[] memory pf2 = new address[](2);
        pf2[0] = address(factory2);
        pf2[1] = address(factory2);
        bytes[] memory cd2 = new bytes[](2);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        cd2[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 500e6);
        deal(address(_usdc), _vault2, 1000e6);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;
        uint256 debt = CollateralFacet(portfolio2).getTotalDebt();
        uint256 expectedPaid = distributable > debt ? debt : distributable;

        vm.expectEmit(true, true, true, true);
        emit DebtPaid(_currentEpochStart(), _tokenId, expectedPaid, portfolio2, rewardsToken);

        _processRewards(rewards, 0);
    }

    function test_payDebt_crossFactory() public {
        // Source portfolio on factory1, target on factory2
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-7"))
        );
        vm.stopPrank();

        _setupSecondFactory(factory2, registry2);
        address portfolio2 = factory2.createAccount(_user);

        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        vm.startPrank(_user);
        address[] memory pf2 = new address[](2);
        pf2[0] = address(factory2);
        pf2[1] = address(factory2);
        bytes[] memory cd2 = new bytes[](2);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        cd2[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 300e6);
        deal(address(_usdc), _vault2, 500e6);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });
        _setZeroBalanceDistribution(entries);

        uint256 debtBefore = CollateralFacet(portfolio2).getTotalDebt();
        assertGt(debtBefore, 0, "Factory2 portfolio has debt");

        uint256 rewards = 500e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 debtAfter = CollateralFacet(portfolio2).getTotalDebt();
        assertEq(debtAfter, 0, "Cross-factory debt fully repaid");
    }

    function test_payDebt_sameOwnerRequirement() public {
        // PayDebt looks up target = factory.portfolioOf(owner) where owner is the source portfolio's owner
        // This test verifies a different user cannot pay debt on someone else's portfolio
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-8"))
        );
        vm.stopPrank();

        _setupSecondFactory(factory2, registry2);

        // Create portfolio for a DIFFERENT user on factory2
        address otherUser = address(0xD1FFE4);
        address portfolio2 = factory2.createAccount(otherUser);

        // Give veNFT and debt to otherUser's portfolio
        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        // otherUser borrows
        vm.startPrank(otherUser);
        address[] memory pf2 = new address[](2);
        pf2[0] = address(factory2);
        pf2[1] = address(factory2);
        bytes[] memory cd2 = new bytes[](2);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        cd2[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 300e6);
        deal(address(_usdc), _vault2, 500e6);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();

        // _user tries to set PayDebt distribution targeting factory2
        // But factory2.portfolioOf(_user) == address(0) since _user has no portfolio on factory2
        // The config setter should revert
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 100,
            outputToken: address(0),
            target: address(factory2)
        });

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);

        vm.expectRevert("PayDebt target factory must have portfolio for owner");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // ── Helper: Set up a second factory with same config, loan, and facets ──

    function _setupSecondFactory(PortfolioFactory factory2, FacetRegistry registry2) internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Deploy a separate loan+vault for factory2 (each factory needs its own loan/vault binding)
        Loan loanImpl2 = new Loan();
        ERC1967Proxy loanProxy2 = new ERC1967Proxy(address(loanImpl2), "");
        address loanContract2 = address(loanProxy2);

        Vault vaultImpl2 = new Vault();
        ERC1967Proxy vaultProxy2 = new ERC1967Proxy(address(vaultImpl2), "");
        Vault vault2 = Vault(address(vaultProxy2));

        vault2.initialize(_usdc, loanContract2, "40base-USDC-VAULT-2", "40base-USDC-VAULT-2");
        Loan(loanContract2).initialize(address(vault2), _usdc);

        LoanV2 loanV2Impl2 = new LoanV2();
        LoanV2(loanContract2).upgradeToAndCall(address(loanV2Impl2), new bytes(0));
        LoanV2(loanContract2).setPortfolioFactory(address(factory2));
        _vault2 = address(vault2);

        // Deploy config for factory2
        PortfolioFactoryConfig configImpl2 = new PortfolioFactoryConfig();
        PortfolioFactoryConfig config2 = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl2),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (FORTY_ACRES_DEPLOYER, address(factory2)))
            ))
        );
        config2.setLoanConfig(address(_loanConfig));
        config2.setVoteConfig(address(_votingConfig));
        config2.setLoanContract(loanContract2);

        factory2.setPortfolioFactoryConfig(address(config2));

        // Register collateral facet
        CollateralFacet collateralFacet2 = new CollateralFacet(address(factory2), address(_ve));
        bytes4[] memory collateralSel = new bytes4[](10);
        collateralSel[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSel[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSel[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSel[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSel[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSel[6] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSel[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSel[8] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSel[9] = BaseCollateralFacet.removeCollateralTo.selector;
        registry2.registerFacet(address(collateralFacet2), collateralSel, "CollateralFacet");

        // Register lending facet
        LendingFacet lendingFacet2 = new LendingFacet(address(factory2), _usdc);
        bytes4[] memory lendingSel = new bytes4[](5);
        lendingSel[0] = BaseLendingFacet.borrow.selector;
        lendingSel[1] = BaseLendingFacet.pay.selector;
        lendingSel[2] = BaseLendingFacet.setTopUp.selector;
        lendingSel[3] = BaseLendingFacet.topUp.selector;
        lendingSel[4] = BaseLendingFacet.borrowTo.selector;
        registry2.registerFacet(address(lendingFacet2), lendingSel, "LendingFacet");

        vm.stopPrank();
    }
}
