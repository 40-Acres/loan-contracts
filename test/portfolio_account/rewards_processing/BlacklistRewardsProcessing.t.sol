// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {MockBlacklistableERC20} from "../../mocks/MockBlacklistableERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DeployRewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployRewardsProcessingFacet.s.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

/**
 * @title BlacklistRewardsProcessingTest
 * @dev Tests that PayBalance and PayToRecipient handle blacklisted recipients
 *      by sending tokens to the user's wallet account instead.
 */
contract BlacklistRewardsProcessingTest is Test, LocalSetup {
    RewardsProcessingFacet public rewardsProcessingFacet;
    MockOdosRouterRL public mockRouter;
    MockBlacklistableERC20 public blacklistToken;

    uint256 public rewardsAmount = 1000e6;
    address public blacklistedRecipient = address(0xB1AC);

    // Wallet factory and account
    PortfolioFactory public walletFactory;
    address public walletAccount;

    function setUp() public override {
        super.setUp();

        // Deploy RewardsProcessingFacet
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_swapConfig), address(_ve), _vault);
        vm.stopPrank();

        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);

        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        // Deploy blacklistable token
        blacklistToken = new MockBlacklistableERC20("Blacklist Token", "BLT", 6);

        // Deploy wallet factory at salt bytes32(0) and create wallet account for user
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (walletFactory,) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        walletAccount = walletFactory.createAccount(_user);

        // Set rewards token and recipient via multicall
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](3);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        portfolioFactories[2] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](3);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            address(blacklistToken)
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRecipient.selector,
            blacklistedRecipient
        );
        calldatas[2] = abi.encodeWithSelector(
            BaseCollateralFacet.addCollateral.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Approve swap target
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();
    }

    function _fundPortfolioWithBlacklistToken() internal {
        blacklistToken.mint(_portfolioAccount, rewardsAmount);
    }

    function _setZeroBalanceDistribution(UserRewardsConfig.DistributionEntry[] memory entries) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setZeroBalanceDistribution.selector,
            entries
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // ─── PayBalance: blacklisted recipient → tokens go to wallet account ───

    function testPayBalanceBlacklistedRecipientSendsToWallet() public {
        _fundPortfolioWithBlacklistToken();

        // Set distribution: PayBalance 100% to blacklisted recipient
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: blacklistedRecipient
        });
        _setZeroBalanceDistribution(entries);

        // Blacklist the recipient
        blacklistToken.setBlacklisted(blacklistedRecipient, true);

        uint256 walletBefore = blacklistToken.balanceOf(walletAccount);
        uint256 recipientBefore = blacklistToken.balanceOf(blacklistedRecipient);

        // Process rewards
        vm.startPrank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(_tokenId, rewardsAmount, noSwap, 0);
        vm.stopPrank();

        // Calculate expected: rewardsAmount - zeroBalanceFee
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedToWallet = rewardsAmount - feeAmount;

        // Recipient should have received nothing
        assertEq(blacklistToken.balanceOf(blacklistedRecipient), recipientBefore, "Blacklisted recipient should receive nothing");
        // Wallet account should have received the tokens
        assertEq(blacklistToken.balanceOf(walletAccount), walletBefore + expectedToWallet, "Wallet account should receive tokens");
        // Portfolio account should be empty
        assertEq(blacklistToken.balanceOf(_portfolioAccount), 0, "Portfolio should have sent all tokens");
    }

    // ─── PayToRecipient (same token): blacklisted recipient → tokens go to wallet account ───

    function testPayToRecipientSameTokenBlacklistedRecipientSendsToWallet() public {
        _fundPortfolioWithBlacklistToken();

        // Set distribution: PayToRecipient 100%, same token (outputToken = address(0))
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0),
            target: blacklistedRecipient
        });
        _setZeroBalanceDistribution(entries);

        // Blacklist the recipient
        blacklistToken.setBlacklisted(blacklistedRecipient, true);

        uint256 walletBefore = blacklistToken.balanceOf(walletAccount);
        uint256 recipientBefore = blacklistToken.balanceOf(blacklistedRecipient);

        // Process rewards
        vm.startPrank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(_tokenId, rewardsAmount, noSwap, 0);
        vm.stopPrank();

        // Calculate expected: rewardsAmount - zeroBalanceFee
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedToWallet = rewardsAmount - feeAmount;

        // Recipient should have received nothing
        assertEq(blacklistToken.balanceOf(blacklistedRecipient), recipientBefore, "Blacklisted recipient should receive nothing");
        // Wallet account should have received the tokens
        assertEq(blacklistToken.balanceOf(walletAccount), walletBefore + expectedToWallet, "Wallet account should receive tokens");
        // Portfolio account should be empty
        assertEq(blacklistToken.balanceOf(_portfolioAccount), 0, "Portfolio should have sent all tokens");
    }

    // ─── PayToRecipient (different token via swap): blacklisted recipient → swapped tokens go to wallet ───

    function testPayToRecipientSwapBlacklistedRecipientSendsToWallet() public {
        // Use regular USDC as rewards token for this test (fees paid in USDC)
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            address(_usdc)
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Fund portfolio with USDC
        deal(address(_usdc), _portfolioAccount, rewardsAmount);

        // Set distribution: PayToRecipient 100% with blacklistToken as outputToken
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(blacklistToken),
            target: blacklistedRecipient
        });
        _setZeroBalanceDistribution(entries);

        // Calculate expected swap amounts
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 amountToSwap = rewardsAmount - feeAmount;
        uint256 swapOutputAmount = amountToSwap; // 1:1 for simplicity

        // Fund mock router with blacklistToken for the swap
        blacklistToken.mint(address(mockRouter), swapOutputAmount);

        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(_usdc),
            address(blacklistToken),
            amountToSwap,
            swapOutputAmount,
            _portfolioAccount
        );

        // Pre-approve router for swap
        vm.prank(_portfolioAccount);
        IERC20(address(_usdc)).approve(address(mockRouter), amountToSwap);

        // Blacklist the recipient on the output token
        blacklistToken.setBlacklisted(blacklistedRecipient, true);

        uint256 walletBefore = blacklistToken.balanceOf(walletAccount);
        uint256 recipientBefore = blacklistToken.balanceOf(blacklistedRecipient);

        // Process rewards — swap succeeds, transfer to blacklisted recipient fails
        vm.startPrank(_authorizedCaller);
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
        rewardsProcessingFacet.processRewards(_tokenId, rewardsAmount, swapParams, 0);
        vm.stopPrank();

        // Recipient should have received nothing
        assertEq(blacklistToken.balanceOf(blacklistedRecipient), recipientBefore, "Blacklisted recipient should receive nothing");
        // Wallet account should have received the swapped tokens
        assertEq(blacklistToken.balanceOf(walletAccount), walletBefore + swapOutputAmount, "Wallet account should receive swapped tokens");
        // Portfolio USDC should be empty
        assertEq(IERC20(address(_usdc)).balanceOf(_portfolioAccount), 0, "Portfolio should have sent all USDC");
    }

    // ─── Verify non-blacklisted path still works normally ───

    function testPayBalanceNonBlacklistedRecipientWorksNormally() public {
        _fundPortfolioWithBlacklistToken();

        // Set distribution: PayBalance 100% to non-blacklisted recipient
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayBalance,
            percentage: 100,
            outputToken: address(0),
            target: blacklistedRecipient
        });
        _setZeroBalanceDistribution(entries);

        // Do NOT blacklist the recipient
        uint256 recipientBefore = blacklistToken.balanceOf(blacklistedRecipient);
        uint256 walletBefore = blacklistToken.balanceOf(walletAccount);

        vm.startPrank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(_tokenId, rewardsAmount, noSwap, 0);
        vm.stopPrank();

        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedToRecipient = rewardsAmount - feeAmount;

        // Recipient should receive tokens normally
        assertEq(blacklistToken.balanceOf(blacklistedRecipient), recipientBefore + expectedToRecipient, "Recipient should receive tokens");
        // Wallet should receive nothing
        assertEq(blacklistToken.balanceOf(walletAccount), walletBefore, "Wallet should not receive tokens");
    }

    function testPayToRecipientNonBlacklistedRecipientWorksNormally() public {
        _fundPortfolioWithBlacklistToken();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0),
            target: blacklistedRecipient
        });
        _setZeroBalanceDistribution(entries);

        // Do NOT blacklist the recipient
        uint256 recipientBefore = blacklistToken.balanceOf(blacklistedRecipient);
        uint256 walletBefore = blacklistToken.balanceOf(walletAccount);

        vm.startPrank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(_tokenId, rewardsAmount, noSwap, 0);
        vm.stopPrank();

        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedToRecipient = rewardsAmount - feeAmount;

        assertEq(blacklistToken.balanceOf(blacklistedRecipient), recipientBefore + expectedToRecipient, "Recipient should receive tokens");
        assertEq(blacklistToken.balanceOf(walletAccount), walletBefore, "Wallet should not receive tokens");
    }
}
