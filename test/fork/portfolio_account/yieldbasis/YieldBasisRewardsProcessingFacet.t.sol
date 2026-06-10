// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {veYieldBasisFacet} from "../../../../src/facets/account/veyieldbasis/veYieldBasisFacet.sol";
import {veYieldBasisRewardsProcessingFacet} from "../../../../src/facets/account/veyieldbasis/veYieldBasisRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {UserRewardsConfig} from "../../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DynamicCollateralFacet} from "../../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ERC721ReceiverFacet} from "../../../../src/facets/ERC721ReceiverFacet.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IYieldBasisVotingEscrow} from "../../../../src/interfaces/IYieldBasisVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {veYieldBasisAdapter} from "../../../../src/adapters/veYieldBasisAdapter.sol";
import {YieldBasisFaucet} from "../../../../src/faucets/YieldBasisFaucet.sol";
import {ILendingPool} from "../../../../src/interfaces/ILendingPool.sol";
import {SwapMod} from "../../../../src/facets/account/swap/SwapMod.sol";

/**
 * @title MockLendingPool
 * @dev Mock lending pool for testing
 */
contract MockLendingPool is ILendingPool {
    address public immutable _lendingAsset;
    address public immutable _lendingVault;
    uint256 public _activeAssets;
    address public _portfolioFactory;

    constructor(address lendingAsset_, address lendingVault_) {
        _lendingAsset = lendingAsset_;
        _lendingVault = lendingVault_;
    }

    function setPortfolioFactory(address factory) external {
        _portfolioFactory = factory;
    }

    function getPortfolioFactory() external view returns (address) {
        return _portfolioFactory;
    }

    function borrowFromPortfolio(uint256) external pure returns (uint256) {
        return 0;
    }

    function payFromPortfolio(uint256 totalPayment, uint256) external pure returns (uint256) { return totalPayment; }

    function lendingAsset() external view returns (address) {
        return _lendingAsset;
    }

    function lendingVault() external view returns (address) {
        return _lendingVault;
    }

    function activeAssets() external view returns (uint256) {
        return _activeAssets;
    }

    function depositRewards(uint256) external {}

    function setActiveAssets(uint256 amount) external {
        _activeAssets = amount;
    }

    function getDebtBalance(address) external pure returns (uint256) {
        return 0;
    }

    function getEffectiveDebtBalance(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title MockVault
 * @dev Mock ERC4626 vault for testing
 */
contract MockVault {
    address public immutable _asset;
    uint256 public totalDeposited;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function deposit(uint256 assets, address) external returns (uint256) {
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        totalDeposited += assets;
        return assets;
    }

    // Non-binding supply stub: large so the supply-side maxLoan cap never binds
    // (matches pre-regression behavior where totalAssets was not read). maxLoanIgnoreSupply,
    // used by the LTV/underwater path, does not depend on this.
    function totalAssets() external pure returns (uint256) { return 1e36; }
}

contract YieldBasisRewardsProcessingFacetTest is Test {
    // YieldBasis Protocol Addresses (Ethereum Mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Test actors
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public user = address(0x40ac2e);
    address public authorizedCaller = address(0xaaaaa);
    address public recipient = address(0xbbbbb);

    // Contracts
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LoanConfig public loanConfig;
    VotingConfig public votingConfig;
    SwapConfig public swapConfig;

    // Portfolio account
    address public portfolioAccount;

    // Facets
    veYieldBasisFacet public yieldBasisFacet;
    veYieldBasisRewardsProcessingFacet public rewardsProcessingFacet;
    DynamicCollateralFacet public collateralFacet;

    // YieldBasis contracts
    IYieldBasisVotingEscrow public veYB = IYieldBasisVotingEscrow(VE_YB);
    IERC20 public ybToken = IERC20(YB);

    // Mock lending contracts
    MockLendingPool public mockLendingPool;
    MockVault public mockVault;

    // Adapter and faucet
    veYieldBasisAdapter public veYBAdapter;
    YieldBasisFaucet public faucet;

    // Lock amount for tests
    uint256 public constant LOCK_AMOUNT = 1000 ether;

    function setUp() public {
        // Fork Ethereum mainnet
        uint256 fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);

        vm.startPrank(DEPLOYER);

        // Deploy PortfolioManager
        portfolioManager = new PortfolioManager(DEPLOYER);

        // Deploy factory with facet registry
        (portfolioFactory, facetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yieldbasis-rewards-test")))
        );

        // Deploy configs
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (portfolioFactoryConfig, votingConfig, loanConfig, swapConfig) = configDeployer.deploy(address(portfolioFactory), DEPLOYER);

        // Deploy mock vault and lending pool
        mockVault = new MockVault(USDC);
        mockLendingPool = new MockLendingPool(USDC, address(mockVault));

        // Configure the PortfolioFactoryConfig with the mock lending pool
        mockLendingPool.setPortfolioFactory(address(portfolioFactory));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        portfolioFactoryConfig.setLoanContract(address(mockLendingPool));

        // Fund the mock vault with USDC
        deal(USDC, address(mockVault), 1_000_000 * 1e6);

        // Deploy DynamicCollateralFacet
        collateralFacet = new DynamicCollateralFacet(
            address(portfolioFactory),
            VE_YB
        );
        bytes4[] memory collateralSelectors = new bytes4[](8);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        facetRegistry.registerFacet(address(collateralFacet), collateralSelectors, "DynamicCollateralFacet");

        // Deploy YieldBasis VotingEscrow Adapter
        veYBAdapter = new veYieldBasisAdapter(VE_YB);

        // Deploy YieldBasis Faucet (rate limit: 100 dispenses per hour)
        faucet = new YieldBasisFaucet(
            address(portfolioManager),
            YB,
            1
        );
        deal(YB, address(faucet), 1000 ether);

        // Deploy veYieldBasisFacet
        yieldBasisFacet = new veYieldBasisFacet(
            address(portfolioFactory),
            VE_YB,
            YB,
            address(veYBAdapter),
            address(faucet)
        );
        bytes4[] memory yieldBasisSelectors = new bytes4[](3);
        yieldBasisSelectors[0] = veYieldBasisFacet.createLock.selector;
        yieldBasisSelectors[1] = veYieldBasisFacet.increaseLock.selector;
        yieldBasisSelectors[2] = veYieldBasisFacet.depositLock.selector;
        facetRegistry.registerFacet(address(yieldBasisFacet), yieldBasisSelectors, "veYieldBasisFacet");

        // Deploy ERC721ReceiverFacet
        ERC721ReceiverFacet erc721ReceiverFacet = new ERC721ReceiverFacet();
        bytes4[] memory erc721ReceiverSelectors = new bytes4[](1);
        erc721ReceiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        facetRegistry.registerFacet(address(erc721ReceiverFacet), erc721ReceiverSelectors, "ERC721ReceiverFacet");

        // Deploy veYieldBasisRewardsProcessingFacet
        // Rewards arrive as YB: pass address(0) for the rewards-token vault and YB
        // as the defaultToken so getRewardsToken() returns YB. Otherwise the rewards
        // token would be the lending vault's USDC, which doesn't match the deal(YB)
        // funding pattern these tests use.
        rewardsProcessingFacet = new veYieldBasisRewardsProcessingFacet(
            address(portfolioFactory),
            address(swapConfig),
            VE_YB,
            address(veYBAdapter),
            address(0),
            YB
        );
        bytes4[] memory rewardsSelectors = new bytes4[](5);
        rewardsSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        facetRegistry.registerFacet(address(rewardsProcessingFacet), rewardsSelectors, "veYieldBasisRewardsProcessingFacet");

        // Deploy RewardsConfigFacet
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(address(portfolioFactory), address(swapConfig));
        bytes4[] memory rewardsConfigSelectors = new bytes4[](6);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        facetRegistry.registerFacet(address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");

        // Set authorized caller
        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        vm.stopPrank();

        // Create portfolio account for user
        portfolioAccount = portfolioFactory.createAccount(user);

        // Deal tokens to user
        deal(YB, user, LOCK_AMOUNT * 10);
        deal(USDC, user, 1_000_000 * 1e6);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ============ Helper Functions ============

    function _createLockForUser() internal {
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(veYieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();
    }

    function _setRewardsOption(UserRewardsConfig.RewardsOption option, uint256 percentage) internal {
        vm.startPrank(user);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: option,
            percentage: percentage,
            outputToken: address(0),
            target: address(0)
        });

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);

        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();
    }

    function _setRecipient(address _recipient) internal {
        vm.startPrank(user);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, _recipient);

        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();
    }

    // ============ Basic Tests ============

    function testGetRewardsToken() public {
        _createLockForUser();

        // With vault=address(0), the rewards token falls back to the configured
        // defaultToken (YB) — matching how YB gauge rewards are denominated.
        address rewardsToken = RewardsProcessingFacet(portfolioAccount).getRewardsToken();
        assertEq(rewardsToken, YB, "Rewards token should be YB");
    }

    function testSetZeroBalanceDistribution() public {
        _createLockForUser();

        _setRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 25);

        UserRewardsConfig.DistributionEntry[] memory entries = RewardsConfigFacet(portfolioAccount).getZeroBalanceDistribution();
        assertEq(entries.length, 1, "Should have 1 distribution entry");
        assertEq(uint256(entries[0].option), uint256(UserRewardsConfig.RewardsOption.IncreaseCollateral), "Option should be IncreaseCollateral");
        assertEq(entries[0].percentage, 25, "Percentage should be 25");
    }

    function testSetRecipient() public {
        _createLockForUser();

        _setRecipient(recipient);

        // No direct getter for recipient, but we can verify via processRewards behavior
    }

    // ============ IncreaseCollateral Tests ============

    function testIncreaseCollateralWithYBToken() public {
        _createLockForUser();

        // Get initial locked amount
        uint256 initialLockedAmount = uint256(uint128(veYB.locked(portfolioAccount).amount));

        // Set rewards option to IncreaseCollateral with 100%
        _setRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 100);

        // Deal YB to portfolio account (simulating rewards)
        uint256 rewardsAmount = 100 ether;
        deal(YB, portfolioAccount, rewardsAmount);

        // Set recipient so zero balance rewards can be processed
        _setRecipient(recipient);

        // Get the tokenId for the lock
        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Process rewards as authorized caller
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            rewardsAmount,
            noSwap,
            0 // no gas reclamation
        );

        // Verify lock amount increased
        uint256 finalLockedAmount = uint256(uint128(veYB.locked(portfolioAccount).amount));

        // With IncreaseCollateral option at 100%, the rewards amount minus zero balance fee goes to collateral
        // veYB rounds down slightly due to lock mechanics
        uint256 zeroBalanceFee = rewardsAmount * loanConfig.getZeroBalanceFee() / 10000;
        uint256 expectedIncrease = rewardsAmount - zeroBalanceFee;
        assertApproxEqAbs(
            finalLockedAmount - initialLockedAmount,
            expectedIncrease,
            expectedIncrease / 100, // 1% tolerance for veYB rounding
            "Lock amount should increase by rewards amount"
        );
    }

    function testIncreaseCollateralPartialPercentage() public {
        _createLockForUser();

        // Get initial locked amount
        uint256 initialLockedAmount = uint256(uint128(veYB.locked(portfolioAccount).amount));

        // Set rewards option to IncreaseCollateral with 25%
        _setRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 25);

        // Deal YB to portfolio account
        uint256 rewardsAmount = 100 ether;
        deal(YB, portfolioAccount, rewardsAmount);

        // Set recipient
        _setRecipient(recipient);

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Process rewards
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            rewardsAmount,
            noSwap,
            0
        );

        // Verify lock amount increased by 25% of rewards after zero balance fee
        uint256 finalLockedAmount = uint256(uint128(veYB.locked(portfolioAccount).amount));
        uint256 zeroBalanceFee = rewardsAmount * loanConfig.getZeroBalanceFee() / 10000;
        uint256 afterFee = rewardsAmount - zeroBalanceFee;
        uint256 expectedIncrease = afterFee * 25 / 100; // 25% of post-fee amount goes to collateral
        assertApproxEqAbs(
            finalLockedAmount - initialLockedAmount,
            expectedIncrease,
            expectedIncrease / 100,
            "Lock amount should increase by 25% of rewards"
        );
    }

    // ============ PayToRecipient Tests ============

    function testPayToRecipientOption() public {
        _createLockForUser();

        // Set rewards option to PayToRecipient with 50%
        _setRewardsOption(UserRewardsConfig.RewardsOption.PayToRecipient, 50);

        // Set recipient
        _setRecipient(recipient);

        // Deal YB to portfolio account
        uint256 rewardsAmount = 100 ether;
        deal(YB, portfolioAccount, rewardsAmount);

        uint256 recipientBalanceBefore = ybToken.balanceOf(recipient);

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Process rewards
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            rewardsAmount,
            noSwap,
            0
        );

        uint256 recipientBalanceAfter = ybToken.balanceOf(recipient);

        // Zero balance fee is deducted from the full rewardsAmount first.
        // Then the remaining is split: 50% PayToRecipient + 50% remainder → both go to recipient.
        uint256 zeroBalanceFee = rewardsAmount * loanConfig.getZeroBalanceFee() / 10000;
        uint256 expectedRecipient = rewardsAmount - zeroBalanceFee;
        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            expectedRecipient,
            "Recipient should receive rewards minus zero balance fee"
        );
    }

    // ============ Gas Reclamation Tests ============

    function testGasReclamation() public {
        _createLockForUser();

        // Set recipient
        _setRecipient(recipient);

        // Deal YB to portfolio account
        uint256 rewardsAmount = 100 ether;
        deal(YB, portfolioAccount, rewardsAmount);

        uint256 callerBalanceBefore = ybToken.balanceOf(authorizedCaller);

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Process rewards with gas reclamation
        SwapMod.RouteParams[4] memory noSwap;
        uint256 gasReclamation = 2 ether; // 2% of rewards
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            rewardsAmount,
            noSwap,
            gasReclamation
        );

        uint256 callerBalanceAfter = ybToken.balanceOf(authorizedCaller);

        // Caller should receive gas reclamation
        assertEq(
            callerBalanceAfter - callerBalanceBefore,
            gasReclamation,
            "Caller should receive gas reclamation"
        );
    }

    function testGasReclamationCappedAt5Percent() public {
        _createLockForUser();

        // Set recipient
        _setRecipient(recipient);

        // Deal YB to portfolio account
        uint256 rewardsAmount = 100 ether;
        deal(YB, portfolioAccount, rewardsAmount);

        uint256 callerBalanceBefore = ybToken.balanceOf(authorizedCaller);

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Try to reclaim 10% (should be capped at 5%)
        SwapMod.RouteParams[4] memory noSwap;
        uint256 gasReclamation = 10 ether;
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            rewardsAmount,
            noSwap,
            gasReclamation
        );

        uint256 callerBalanceAfter = ybToken.balanceOf(authorizedCaller);

        // Caller should only receive 5% (capped)
        assertEq(
            callerBalanceAfter - callerBalanceBefore,
            rewardsAmount * 5 / 100,
            "Gas reclamation should be capped at 5%"
        );
    }

    // ============ Access Control Tests ============

    function testProcessRewardsRevertsForNonAuthorizedCaller() public {
        _createLockForUser();

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Deal YB to portfolio account
        deal(YB, portfolioAccount, 100 ether);

        // Try to process rewards as non-authorized caller
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(user);
        vm.expectRevert();
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            100 ether,
            noSwap,
            0
        );
    }

    function testSetDistributionRevertsForNonOwner() public {
        _createLockForUser();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 25,
            outputToken: address(0),
            target: address(0)
        });

        // Try to set distribution as non-owner
        vm.prank(address(0xdead));
        vm.expectRevert();
        RewardsConfigFacet(portfolioAccount).setZeroBalanceDistribution(entries);
    }

    // ============ Edge Cases ============

    function testProcessRewardsWithZeroAmount() public {
        _createLockForUser();

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Try to process zero rewards
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(authorizedCaller);
        vm.expectRevert();
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            0,
            noSwap,
            0
        );
    }

    function testProcessRewardsWithInsufficientBalance() public {
        _createLockForUser();

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Don't deal any YB to portfolio account
        // Try to process rewards without sufficient balance
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(authorizedCaller);
        vm.expectRevert();
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            100 ether,
            noSwap,
            0
        );
    }

    // ============ Collateral Update Verification ============

    function testCollateralUpdatedAfterIncreaseCollateral() public {
        _createLockForUser();

        // Get initial collateral
        uint256 initialCollateral = DynamicCollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // Set rewards option to IncreaseCollateral
        _setRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 100);

        // Deal YB to portfolio account
        uint256 rewardsAmount = 100 ether;
        deal(YB, portfolioAccount, rewardsAmount);

        _setRecipient(recipient);

        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Process rewards
        SwapMod.RouteParams[4] memory noSwap;
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(
            tokenId,
            rewardsAmount,
            noSwap,
            0
        );

        // Verify collateral increased in CollateralManager
        uint256 finalCollateral = DynamicCollateralFacet(portfolioAccount).getTotalLockedCollateral();

        assertTrue(
            finalCollateral > initialCollateral,
            "Collateral should have increased after processRewards with IncreaseCollateral option"
        );
    }
}
