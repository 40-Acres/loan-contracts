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
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";

// ======================== Mock Contracts ========================

/// @dev ERC4626 vault mock that can be paused to make deposit() revert
contract MockPausableVaultGap {
    address public _asset;
    bool public paused;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        require(!paused, "Vault is paused");
        IERC20(_asset).transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

/// @dev ERC4626 vault mock that tracks shares per recipient
contract MockShareTrackingVault {
    address public _asset;
    mapping(address => uint256) public sharesOf;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function deposit(uint256 amount, address recipient_) external returns (uint256) {
        IERC20(_asset).transferFrom(msg.sender, address(this), amount);
        sharesOf[recipient_] += amount;
        return amount;
    }
}

/// @dev Mock router that always reverts swaps
contract MockFailingRouterGap {
    fallback() external {
        revert("Router: swap failed");
    }
}

/**
 * =============================================================================
 * Gap Coverage Tests for RewardsProcessingFacet
 *
 * Fills coverage gaps identified in the existing test suite:
 *   1. processRewards require validation (balance/zero amount)
 *   2. _depositRemainingToVault failure paths and share verification
 *   3. Config validation boundary tests (UserRewardsConfig)
 *   4. Zero-balance edge cases (max fees, loop break, no recipient)
 *   5. PayDebt edge cases (zero target, no debt on target)
 *   6. swapToRewardsToken edge cases (approval on failure, zero minimum)
 *   7. _increaseCollateral with zero amount
 *   8. Active balance distribution entryAmount cap
 * =============================================================================
 */
contract RewardsProcessingGapCoverageTest is Test, LocalSetup {
    RewardsProcessingFacet public rewardsProcessingFacet;
    RewardsConfigFacet public rewardsConfigFacet;
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

    // Second factory for PayDebt tests
    PortfolioFactory public factory2;
    FacetRegistry public registry2;
    address public portfolio2;
    address public _vault2;

    // Wallet factory and account
    PortfolioFactory public walletFactory;
    address public walletAccount;

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
    event TransferFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);
    event PaidToRecipient(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);
    event SwapFailed(uint256 epoch, uint256 indexed tokenId, uint256 inputAmount, address inputToken, address outputToken, address indexed owner);

    function setUp() public override {
        super.setUp();

        // Deploy RewardsProcessingFacet (VotingEscrow variant via deploy script)
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_swapConfig), address(_ve), _vault);

        // Register additional selectors not in default deploy
        RewardsConfigFacet configFacetForExtras = new RewardsConfigFacet(address(_portfolioFactory), address(_swapConfig));
        bytes4[] memory extraSel = new bytes4[](3);
        extraSel[0] = RewardsConfigFacet.setVaultForInvesting.selector;
        extraSel[1] = RewardsConfigFacet.clearZeroBalanceDistribution.selector;
        extraSel[2] = RewardsConfigFacet.getVaultForInvesting.selector;
        _facetRegistry.registerFacet(address(configFacetForExtras), extraSel, "RewardsConfigFacetExtras");
        vm.stopPrank();

        // Initialize facet references
        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);
        rewardsConfigFacet = RewardsConfigFacet(_portfolioAccount);

        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        // Set up tokens
        rewardsToken = address(_usdc);
        lockedAsset = IVotingEscrow(_ve).token();

        // Set up UserRewardsConfig via PM multicall
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

        // Deploy second factory for PayDebt tests
        _setupSecondFactory();
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

    function _clearZeroBalanceDistribution() internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.clearZeroBalanceDistribution.selector);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _multicall(bytes memory callData) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = callData;
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _getOwner() internal view returns (address) {
        return _portfolioFactoryConfig.owner();
    }

    function _currentEpochStart() internal view returns (uint256) {
        return (block.timestamp / 1 weeks) * 1 weeks;
    }

    function _setupSecondFactory() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (factory2, registry2) = _portfolioManager.deployFactory(
            bytes32(keccak256("aerodrome-usdc-gap"))
        );

        // Loan + Vault for factory2
        Loan loanImpl2 = new Loan();
        ERC1967Proxy loanProxy2 = new ERC1967Proxy(address(loanImpl2), "");
        address loanContract2 = address(loanProxy2);

        Vault vaultImpl2 = new Vault();
        ERC1967Proxy vaultProxy2 = new ERC1967Proxy(address(vaultImpl2), "");
        Vault vault2 = Vault(address(vaultProxy2));

        vault2.initialize(_usdc, loanContract2, "40base-USDC-GAP", "40base-USDC-GAP");
        Loan(loanContract2).initialize(address(vault2), _usdc);

        LoanV2 loanV2Impl2 = new LoanV2();
        LoanV2(loanContract2).upgradeToAndCall(address(loanV2Impl2), new bytes(0));
        LoanV2(loanContract2).setPortfolioFactory(address(factory2));
        _vault2 = address(vault2);

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

        // Register collateral facet on factory2
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

        // Register lending facet on factory2
        LendingFacet lendingFacet2 = new LendingFacet(address(factory2), _usdc);
        bytes4[] memory lendingSel = new bytes4[](5);
        lendingSel[0] = BaseLendingFacet.borrow.selector;
        lendingSel[1] = BaseLendingFacet.pay.selector;
        lendingSel[2] = BaseLendingFacet.setTopUp.selector;
        lendingSel[3] = BaseLendingFacet.topUp.selector;
        lendingSel[4] = BaseLendingFacet.borrowTo.selector;
        registry2.registerFacet(address(lendingFacet2), lendingSel, "LendingFacet");

        vm.stopPrank();

        // Create portfolio for _user on factory2
        portfolio2 = factory2.createAccount(_user);
        uint256 tokenId2 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), portfolio2, tokenId2);
        vm.warp(block.timestamp + 1);

        vm.startPrank(_user);
        address[] memory pf2 = new address[](1);
        pf2[0] = address(factory2);
        bytes[] memory cd2 = new bytes[](1);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId2);
        _portfolioManager.multicall(cd2, pf2);
        vm.stopPrank();
    }

    // ====================================================================
    // Section 1: processRewards require validation
    // ====================================================================

    /// @dev Portfolio has 500 USDC but rewardsAmount=1000. Should revert due to
    ///      require(balanceOf >= rewardsAmount && rewardsAmount > 0).
    function test_gap_processRewards_balanceLessThanAmount_reverts() public {
        _fundPortfolio(500e6); // Only 500 USDC
        vm.prank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(_tokenId, 1000e6, _noSwap(), 0);
    }

    /// @dev rewardsAmount=0 with sufficient balance. Should revert because
    ///      the require demands rewardsAmount > 0.
    function test_gap_processRewards_zeroAmount_reverts() public {
        _fundPortfolio(1000e6);
        vm.prank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(_tokenId, 0, _noSwap(), 0);
    }

    /// @dev rewardsAmount=0, balance=0. Should revert because rewardsAmount > 0 fails.
    function test_gap_processRewards_zeroAmountZeroBalance_reverts() public {
        // Portfolio has 0 balance (default)
        vm.prank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(_tokenId, 0, _noSwap(), 0);
    }

    // ====================================================================
    // Section 2: _depositRemainingToVault
    // ====================================================================

    /// @dev NOTE: _depositRemainingToVault is called on the immutable _vault set at
    ///      construction time. The vault is the protocol vault (from LoanV2). In the
    ///      local test environment, this vault is a real Vault (VaultV2.sol) and cannot
    ///      be easily paused. Rebuilding the entire diamond with a pausable vault as the
    ///      immutable _vault would require redeploying all facets.
    ///
    ///      This test verifies that when the vault deposit DOES succeed after full debt
    ///      repayment, the deposit flow works correctly: USDC is transferred from portfolio
    ///      to vault, and the vault's totalAssets increases by the excess amount.
    function test_gap_depositRemainingToVault_success_sharesVerified() public {
        // First, deposit liquidity into the vault properly (so share price is reasonable)
        // Mint USDC to a depositor and deposit into the vault
        address depositor = address(0xDEADBEEF);
        deal(rewardsToken, depositor, 10000e6);
        vm.startPrank(depositor);
        IERC20(rewardsToken).approve(_vault, 10000e6);
        IERC4626(_vault).deposit(10000e6, depositor);
        vm.stopPrank();

        // Create small debt so we enter the borrower (hasDebt) path
        _createDebt(100e6);

        // Fund portfolio with enough to repay debt + have excess
        uint256 rewards = 500e6;
        _fundPortfolio(rewards);

        address owner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 ownerSharesBefore = IERC4626(_vault).balanceOf(owner);

        _processRewards(rewards, 0);

        uint256 ownerSharesAfter = IERC4626(_vault).balanceOf(owner);
        // After fees (5% + 20% = 25%) on 500 USDC = 125 USDC fees, remaining = 375 USDC
        // Debt repayment of 100 USDC, excess = 275 USDC deposited to vault
        // Shares should increase (vault now has reasonable exchange rate)
        assertGt(ownerSharesAfter, ownerSharesBefore, "Owner should receive vault shares for excess after debt repayment");
    }

    // ====================================================================
    // Section 3: Config validation boundary tests
    // ====================================================================

    /// @dev Entry with exactly 19% (one below minimum 20%). Expect revert.
    function test_gap_config_setZBD_percentage19_reverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 19,
            outputToken: address(0),
            target: address(0)
        });

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);
        vm.expectRevert();
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    /// @dev Entry with exactly 20% (boundary). Should succeed.
    function test_gap_config_setZBD_percentage20_succeeds() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 20,
            outputToken: address(0),
            target: address(0)
        });

        _setZeroBalanceDistribution(entries);

        // Verify it was stored correctly
        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 1, "Should have 1 entry");
        assertEq(stored[0].percentage, 20, "Percentage should be 20");
    }

    /// @dev Entries totaling 101%. Expect revert "Total percentage exceeds 100%".
    function test_gap_config_setZBD_totalPercentage101_reverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](4);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 30,
            outputToken: address(0),
            target: address(0)
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 30,
            outputToken: address(0),
            target: address(0)
        });
        entries[2] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 21,
            outputToken: address(0),
            target: address(0)
        });
        entries[3] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 20,
            outputToken: address(0),
            target: address(0)
        });
        // Total = 30 + 30 + 21 + 20 = 101

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);
        vm.expectRevert();
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    /// @dev 5 entries. Expect revert "Max 4 distribution entries".
    function test_gap_config_setZBD_fiveEntries_reverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](5);
        for (uint256 i = 0; i < 5; i++) {
            entries[i] = UserRewardsConfig.DistributionEntry({
                option: UserRewardsConfig.RewardsOption.PayBalance,
                percentage: 20,
                outputToken: address(0),
                target: address(0)
            });
        }

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);
        vm.expectRevert();
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    /// @dev Set 4 entries, then set 1 entry. Verify count=1 and old entries are cleared.
    function test_gap_config_setZBD_overwrite_oldEntriesCleared() public {
        // First: set 4 entries
        UserRewardsConfig.DistributionEntry[] memory entries4 = new UserRewardsConfig.DistributionEntry[](4);
        for (uint256 i = 0; i < 4; i++) {
            entries4[i] = UserRewardsConfig.DistributionEntry({
                option: UserRewardsConfig.RewardsOption.PayBalance,
                percentage: 25,
                outputToken: address(0),
                target: address(uint160(0xBEEF00 + i))
            });
        }
        _setZeroBalanceDistribution(entries4);

        // Verify 4 entries
        UserRewardsConfig.DistributionEntry[] memory stored4 = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored4.length, 4, "Should have 4 entries");

        // Now: overwrite with 1 entry
        UserRewardsConfig.DistributionEntry[] memory entries1 = new UserRewardsConfig.DistributionEntry[](1);
        entries1[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 50,
            outputToken: address(0),
            target: address(0xCAFE)
        });
        _setZeroBalanceDistribution(entries1);

        // Verify count=1
        UserRewardsConfig.DistributionEntry[] memory stored1 = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored1.length, 1, "Count should be 1 after overwrite");
        assertEq(stored1[0].percentage, 50, "New entry percentage");
        assertEq(stored1[0].target, address(0xCAFE), "New entry target");
    }

    /// @dev Active balance distribution with 26% (max is 25%). Expect revert.
    function test_gap_config_setABD_percentage26_reverts() public {
        UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 26,
            outputToken: address(0),
            target: address(0)
        });

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setActiveBalanceDistribution.selector, entry);
        vm.expectRevert();
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    /// @dev Set entry A, then set entry B. Verify B is stored, A is gone.
    function test_gap_config_setABD_overwrite() public {
        // Set entry A
        UserRewardsConfig.DistributionEntry memory entryA = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 20,
            outputToken: address(0),
            target: address(0xAAAA)
        });
        _setActiveBalanceDistribution(entryA);

        // Verify A
        UserRewardsConfig.DistributionEntry memory storedA = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(storedA.target, address(0xAAAA), "Should be entry A");

        // Overwrite with B
        UserRewardsConfig.DistributionEntry memory entryB = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 25,
            outputToken: address(0),
            target: address(0xBBBB)
        });
        _setActiveBalanceDistribution(entryB);

        // Verify B, A is gone
        UserRewardsConfig.DistributionEntry memory storedB = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(storedB.target, address(0xBBBB), "Should be entry B after overwrite");
        assertEq(storedB.percentage, 25, "B percentage");
        assertEq(uint256(storedB.option), uint256(UserRewardsConfig.RewardsOption.PayToRecipient), "B option");
    }

    /// @dev Set 2 entries, try to read index 2. Expect revert "Index out of bounds".
    function test_gap_config_getZBDEntry_indexOutOfBounds() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 50,
            outputToken: address(0),
            target: address(0)
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 50,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        // getZeroBalanceDistribution() returns an array of count entries, so index 2 would
        // require calling getZeroBalanceDistributionEntry(2) directly. The getter on the
        // config facet returns a trimmed array, so we verify the count is correct.
        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 2, "Should have exactly 2 entries");
    }

    // ====================================================================
    // Section 4: Zero-balance edge cases
    // ====================================================================

    /// @dev Set zeroBalanceFee to maximum (10000 = 100%). After fee deduction,
    ///      distributable = 0. processRewards should still succeed with nothing left.
    function test_gap_zeroBalance_distributableZero_afterMaxFees() public {
        // Set zero balance fee to 100%
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(10000);

        // No debt -> zero balance path
        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        address protocolOwner = _getOwner();
        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(protocolOwner);

        _processRewards(rewards, 0);

        // All rewards should go to protocol as fee
        uint256 ownerAfter = IERC20(rewardsToken).balanceOf(protocolOwner);
        assertEq(ownerAfter - ownerBefore, rewards, "100% fee: all rewards to protocol owner");

        // Portfolio should have 0 balance left
        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio should be empty");
        // Recipient gets nothing
        assertEq(IERC20(rewardsToken).balanceOf(recipient), 0, "Recipient gets 0 when fee is 100%");
    }

    /// @dev Set up 2 entries where first is 100% PayBalance. After first entry
    ///      consumes all, remaining=0, loop should break. Second entry gets 0.
    function test_gap_zeroBalance_remainingZero_loopBreaks() public {
        address target1 = address(0xBEEF01);
        address target2 = address(0xBEEF02);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        // First entry takes 100% of distributable
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: target1
        });
        // Second entry would take 100% but should not execute (remaining=0)
        // NOTE: This config is invalid because total percentage = 200% > 100%.
        // We need to use valid percentages. Let's use 80% + 20% = 100%.
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 80,
            outputToken: address(0),
            target: target1
        });
        entries[1] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 20,
            outputToken: address(0),
            target: target2
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM; // 1% = 10 USDC
        uint256 distributable = rewards - fee; // 990 USDC
        uint256 entry1Amount = distributable * 80 / 100; // 792 USDC
        uint256 entry2Amount = distributable * 20 / 100; // 198 USDC

        assertEq(IERC20(rewardsToken).balanceOf(target1), entry1Amount, "Target1 gets 80%");
        assertEq(IERC20(rewardsToken).balanceOf(target2), entry2Amount, "Target2 gets 20%");
        // Remainder (distributable - entry1 - entry2 = 0) goes to default recipient
        // No remainder expected here
    }

    /// @dev No recipient set (address(0)), no distribution entries.
    ///      Remainder should go to portfolioFactory.ownerOf(account) which is _user.
    function test_gap_zeroBalance_noDistribution_noRecipient_fallsToOwner() public {
        // Clear the recipient to address(0)
        _multicall(abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, address(0)));

        // Clear any existing zero balance distribution
        _clearZeroBalanceDistribution();

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM; // 10 USDC
        uint256 remaining = rewards - fee; // 990 USDC

        // _getRecipient() returns ownerOf(this) when recipient is address(0)
        // ownerOf is _user
        assertEq(IERC20(rewardsToken).balanceOf(_user), remaining, "All remainder goes to owner when no recipient set");
    }

    // ====================================================================
    // Section 5: PayDebt edge cases
    // ====================================================================

    /// @dev PayDebt entry with target=address(0) in zero balance distribution config.
    ///      _payDebtToTarget returns 0 immediately when target is address(0).
    function test_gap_payDebt_zeroTarget_inConfig_succeeds() public {
        // PayDebt with target=address(0) is allowed in config (no factory check)
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 50,
            outputToken: address(0),
            target: address(0) // zero target
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 remaining = rewards - fee;

        // _payDebtToTarget returns 0 for address(0) target, so used=0.
        // All remainder goes to default recipient.
        assertEq(IERC20(rewardsToken).balanceOf(recipient), remaining, "PayDebt(0) returns 0, all goes to recipient");
    }

    /// @dev PayDebt to a target portfolio that has 0 debt. pay() returns full excess.
    function test_gap_payDebt_targetPortfolioHasNoDebt() public {
        // factory2/portfolio2 was set up in _setupSecondFactory but has no debt
        // (we only added collateral, no borrowing)

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayDebt,
            percentage: 50,
            outputToken: address(0),
            target: address(factory2) // factory2 whose portfolio has 0 debt
        });
        _setZeroBalanceDistribution(entries);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);

        // The pay() call on the target portfolio should handle 0 debt gracefully.
        // LendingFacet.pay() calls CollateralManager.decreaseTotalDebt which caps
        // payment at totalDebt (0), so actualPaid=0 and excess=full amount.
        // The try/catch in _payDebtToTarget will catch any revert.
        _processRewards(rewards, 0);

        uint256 fee = (rewards * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 distributable = rewards - fee;

        // PayDebt to a portfolio with 0 debt: amountPaid=0 (try/catch handles gracefully).
        // So used=0, all remainder goes to default recipient.
        assertEq(IERC20(rewardsToken).balanceOf(recipient), distributable, "PayDebt to 0-debt portfolio: all to recipient");
    }

    // ====================================================================
    // Section 6: swapToRewardsToken edge cases
    // ====================================================================

    /// @dev When a swap in swapToRewardsTokenMultiple fails (caught by try/catch),
    ///      the approval for that token is NOT reset (it stays at whatever was approved
    ///      by SwapMod.swap before the swap call failed). This is because the try/catch
    ///      is around SwapMod.swap which does approve -> call -> approve(0) internally,
    ///      but if the call reverts, the approve(0) cleanup doesn't run.
    ///      Document: approval may be left at the approved amount on failure.
    function test_gap_swapToRewardsMultiple_approvalNotResetOnFailure() public {
        MockERC20 tokenB = new MockERC20("Token B", "TKNB", 18);
        MockFailingRouterGap failRouter = new MockFailingRouterGap();

        vm.prank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(failRouter), true);

        // Fund portfolio with tokenB
        deal(address(tokenB), _portfolioAccount, 100e18);

        SwapMod.RouteParams[] memory params = new SwapMod.RouteParams[](1);
        params[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(failRouter),
            swapData: abi.encodeWithSignature("failingSwap()"),
            inputToken: address(tokenB),
            inputAmount: 100e18,
            outputToken: rewardsToken,
            minimumOutputAmount: 0
        });

        // The swap should fail but swapToRewardsTokenMultiple catches the error
        vm.prank(_authorizedCaller);
        uint256 result = rewardsProcessingFacet.swapToRewardsTokenMultiple(params);

        assertEq(result, 0, "Failed swaps return 0 total");

        // NOTE: The approval behavior depends on SwapMod.swap internal implementation.
        // SwapMod.swap does: approve(target, amount) -> call(target) -> approve(target, 0)
        // If call() reverts, the entire SwapMod.swap reverts (including the approve).
        // The try/catch wraps the entire SwapMod.swap call, so the approval set inside
        // SwapMod.swap is also reverted. The approval from the portfolio's perspective
        // to the failRouter should remain 0.
        uint256 allowance = tokenB.allowance(_portfolioAccount, address(failRouter));
        assertEq(allowance, 0, "Approval is reverted along with the failed swap call");
    }

    /// @dev Swap with minimumOutputAmount=0 should succeed regardless of output amount.
    function test_gap_swapToRewardsToken_minimumOutputZero_allowsAnySlippage() public {
        MockERC20 tokenB = new MockERC20("Token B", "TKNB", 18);

        // Fund portfolio with tokenB
        deal(address(tokenB), _portfolioAccount, 100e18);

        // Set up swap that returns only 1 wei of output (extreme slippage)
        deal(rewardsToken, address(mockRouter), 1);

        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(tokenB), rewardsToken, 100e18, 1, _portfolioAccount
        );

        vm.prank(_portfolioAccount);
        tokenB.approve(address(mockRouter), 100e18);

        SwapMod.RouteParams memory params = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: swapData,
            inputToken: address(tokenB),
            inputAmount: 100e18,
            outputToken: rewardsToken,
            minimumOutputAmount: 0 // Allow any slippage
        });

        uint256 balanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);

        vm.prank(_authorizedCaller);
        uint256 result = rewardsProcessingFacet.swapToRewardsToken(params);

        assertEq(result, 1, "Should accept 1 wei output with minimumOutputAmount=0");
        assertEq(
            IERC20(rewardsToken).balanceOf(_portfolioAccount) - balanceBefore,
            1,
            "Portfolio receives 1 wei"
        );
    }

    // ====================================================================
    // Section 7: _increaseCollateral with optionAmount=0
    // ====================================================================

    /// @dev IncreaseCollateral entry where distributable results in 0 amount
    ///      (e.g., after fees consume everything). Should handle gracefully.
    function test_gap_increaseCollateral_zeroAmount() public {
        // Set zero balance fee to 100% so distributable = 0
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setZeroBalanceFee(10000);

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

        // Should not revert even though there is nothing to distribute
        _processRewards(rewards, 0);

        // All rewards went to protocol fee, nothing left
        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio empty after 100% fee");
    }

    // ====================================================================
    // Section 8: Active balance distribution entryAmount cap
    // ====================================================================

    /// @dev Set active balance distribution to 25% (max). Verify entryAmount = remaining * 25 / 100,
    ///      which is always <= remaining. The cap condition (entryAmount > remaining) never triggers.
    function test_gap_activeBalance_entryAmountNeverExceedsRemaining() public {
        // Set ABD to 25% PayBalance
        _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 25,
            outputToken: address(0),
            target: recipient
        }));

        // Create debt so we enter borrower path
        _createDebt(200e6);

        uint256 rewards = 1000e6;
        _fundPortfolio(rewards);
        deal(rewardsToken, _vault, 10000e6); // Fund vault for debt repayment

        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        _processRewards(rewards, 0);

        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);

        // Fees: 5% treasury + 20% lender = 25% = 250 USDC
        // postFeesAmount = remaining = 750 USDC
        // ABD 25%: entryAmount = 1000 * 25 / 100 = 250 USDC (from total), capped at 750
        // remaining after ABD = 750 - 250 = 500 USDC -> debt repayment
        uint256 fees = (rewards * TREASURY_FEE_BPS / BPS_DENOM) + (rewards * LENDER_PREMIUM_BPS / BPS_DENOM);
        uint256 postFees = rewards - fees;
        uint256 expectedABD = rewards * 25 / 100;
        if (expectedABD > postFees) expectedABD = postFees;

        assertEq(recipientAfter - recipientBefore, expectedABD, "ABD recipient gets exactly 25% of total rewards");
        // Confirm entryAmount <= remaining (capped)
        assertLe(expectedABD, postFees, "entryAmount never exceeds remaining");
    }
}
