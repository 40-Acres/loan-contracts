// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DeployRewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployRewardsProcessingFacet.s.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title RewardsOptionCombinationsTest
 * @dev Comprehensive tests for all combinations of RewardsOption, IncreaseCollateralPercentage,
 *      and FinalRewardsOption in the zero-balance rewards processing flow.
 *
 * Zero-balance flow:
 *   1. Zero balance fee (1% of rewardsAmount)
 *   2. Gas reclamation (up to 5% of rewardsAmount)
 *   3. RewardsOption (user percentage of rewardsAmount) — swapParams[0]
 *   4a. IncreaseCollateralPercentage (percentage of rewardsAmount, capped at remaining) — swapParams[1]
 *   4b. FinalRewardsOption (whatever is left) — swapParams[2]
 */
contract RewardsOptionCombinationsTest is Test, LocalSetup {
    RewardsProcessingFacet public facet;
    MockOdosRouterRL public mockRouter;

    address public rewardsToken;
    address public lockedAsset;
    uint256 public rewardsAmount = 1000e6; // 1000 USDC
    address public recipient = address(0x1234);

    // Loan config: ZBF=100bps(1%), LenderPremium=2000bps(20%), TreasuryFee=500bps(5%)
    uint256 constant ZBF_BPS = 100;

    function setUp() public override {
        super.setUp();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_swapConfig), address(_ve), _vault);
        vm.stopPrank();

        facet = RewardsProcessingFacet(_portfolioAccount);

        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        rewardsToken = address(_usdc);
        lockedAsset = IVotingEscrow(_ve).token();

        // Base config: set rewards token and add collateral
        vm.startPrank(_user);
        address[] memory factories = new address[](2);
        factories[0] = address(_portfolioFactory);
        factories[1] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsToken.selector, rewardsToken);
        calls[1] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _fundRewards() internal {
        deal(rewardsToken, _portfolioAccount, rewardsAmount);
    }

    function _expectedZBF() internal view returns (uint256) {
        return (rewardsAmount * ZBF_BPS) / 10000;
    }

    function _postFeesAmount() internal view returns (uint256) {
        return rewardsAmount - _expectedZBF();
    }

    function _processRewards() internal {
        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[3] memory noSwap;
        facet.processRewards(_tokenId, rewardsAmount, noSwap, 0);
    }

    function _processRewardsWithSwap(SwapMod.RouteParams[3] memory swapParams) internal {
        vm.prank(_authorizedCaller);
        facet.processRewards(_tokenId, rewardsAmount, swapParams, 0);
    }

    /// @dev Configure rewards option + percentage + recipient via multicall
    function _configureRewardsOption(UserRewardsConfig.RewardsOption option, uint256 percentage) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](3);
        factories[0] = address(_portfolioFactory);
        factories[1] = address(_portfolioFactory);
        factories[2] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOption.selector, option);
        calls[1] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOptionPercentage.selector, percentage);
        calls[2] = abi.encodeWithSelector(RewardsProcessingFacet.setRecipient.selector, recipient);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }

    /// @dev Configure increase collateral percentage via multicall
    function _configureIncreaseCollateral(uint256 percentage) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setIncreaseCollateralPercentage.selector, percentage);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }

    /// @dev Configure final rewards option via multicall
    function _configureFinalRewardsOption(UserRewardsConfig.RewardsOption option) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setFinalRewardsOption.selector, option);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }

    /// @dev Build swap params for IncreaseCollateral (USDC → AERO)
    function _buildCollateralSwapParams(uint256 slotIndex, uint256 amountIn, uint256 amountOut) internal view returns (SwapMod.RouteParams[3] memory swapParams) {
        bytes memory swapData = abi.encodeWithSelector(
            mockRouter.executeSwap.selector,
            rewardsToken,       // tokenIn
            lockedAsset,        // tokenOut
            amountIn,           // amountIn (router pulls via transferFrom)
            amountOut,          // amountOut (router deals)
            _portfolioAccount   // receiver
        );
        swapParams[slotIndex] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: swapData,
            inputToken: rewardsToken,
            inputAmount: 0,
            outputToken: lockedAsset,
            minimumOutputAmount: 1
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  1. Default: PayBalance option, no increase collateral, PayBalance final
    //     → Everything (minus ZBF) goes to recipient
    // ═══════════════════════════════════════════════════════════════════════

    function testDefaultPayBalance() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.PayBalance, 0);

        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);
        _processRewards();

        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 expected = rewardsAmount - _expectedZBF();
        assertEq(recipientAfter - recipientBefore, expected, "Recipient should get everything minus ZBF");
        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio should be empty");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. RewardsOption = PayToRecipient (50%)
    //     → 50% to recipient in step 3, rest to recipient in step 4b
    // ═══════════════════════════════════════════════════════════════════════

    function testRewardsOptionPayToRecipient() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.PayToRecipient, 50);

        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);
        _processRewards();

        // 50% of 1000 = 500 in step 3 to recipient
        // remaining = 1000 - 10 ZBF - 500 = 490 → step 4b default (PayBalance) → also to recipient
        // total to recipient = 500 + 490 = 990
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 expected = rewardsAmount - _expectedZBF();
        assertEq(recipientAfter - recipientBefore, expected, "Recipient should get everything minus ZBF");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. RewardsOption = InvestToVault (30%)
    //     → 30% to vault in step 3, rest to recipient in step 4b
    // ═══════════════════════════════════════════════════════════════════════

    function testRewardsOptionInvestToVault() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.InvestToVault, 30);

        address vault = ILoan(_loanContract)._vault();
        uint256 vaultSharesBefore = IERC20(vault).balanceOf(_user);
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        _processRewards();

        uint256 vaultSharesAfter = IERC20(vault).balanceOf(_user);
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);

        // 30% of postFees(990) = 297 to vault
        assertGt(vaultSharesAfter, vaultSharesBefore, "User should have vault shares");

        // remaining = 990 - 297 = 693 → recipient
        uint256 expectedRecipient = _postFeesAmount() - (_postFeesAmount() * 30 / 100);
        assertEq(recipientAfter - recipientBefore, expectedRecipient, "Recipient should get remaining");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  4. RewardsOption = IncreaseCollateral (25%) — needs swap USDC→AERO
    //     → 25% swapped to AERO and locked, rest to recipient
    // ═══════════════════════════════════════════════════════════════════════

    function testRewardsOptionIncreaseCollateral() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 25);

        uint256 optionAmount = _postFeesAmount() * 25 / 100; // 25% of 990 = 247.5 USDC
        uint256 swapOutputAmount = 247e18; // mock AERO out

        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        SwapMod.RouteParams[3] memory swapParams = _buildCollateralSwapParams(0, optionAmount, swapOutputAmount);
        _processRewardsWithSwap(swapParams);

        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);

        // Collateral should have increased
        assertGt(uint256(uint128(lockedAfter.amount)), uint256(uint128(lockedBefore.amount)), "Lock amount should increase");

        // Remaining goes to recipient: 990 - 247.5 = 742.5
        uint256 expectedRecipient = _postFeesAmount() - optionAmount;
        assertEq(recipientAfter - recipientBefore, expectedRecipient, "Recipient should get remaining");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  5. IncreaseCollateralPercentage = 40%, no RewardsOption, PayBalance final
    //     → 40% of rewardsAmount to collateral in step 4a, rest to recipient
    // ═══════════════════════════════════════════════════════════════════════

    function testIncreaseCollateralPercentageOnly() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.PayBalance, 0);
        _configureIncreaseCollateral(40);

        uint256 collateralAmount = _postFeesAmount() * 40 / 100; // 40% of 990 = 396 USDC
        uint256 swapOutputAmount = 396e18; // mock AERO

        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        SwapMod.RouteParams[3] memory swapParams = _buildCollateralSwapParams(1, collateralAmount, swapOutputAmount);
        _processRewardsWithSwap(swapParams);

        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);

        assertGt(uint256(uint128(lockedAfter.amount)), uint256(uint128(lockedBefore.amount)), "Lock should increase");

        // remaining = 990 - 396 collateral = 594 → recipient
        uint256 expectedRecipient = _postFeesAmount() - collateralAmount;
        assertEq(recipientAfter - recipientBefore, expectedRecipient, "Recipient should get rest");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  6. FinalRewardsOption = InvestToVault (no RewardsOption, no increase collateral)
    //     → Everything minus ZBF goes to vault
    // ═══════════════════════════════════════════════════════════════════════

    function testFinalOptionInvestToVault() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.PayBalance, 0);
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.InvestToVault);

        address vault = ILoan(_loanContract)._vault();
        uint256 vaultSharesBefore = IERC20(vault).balanceOf(_user);

        _processRewards();

        uint256 vaultSharesAfter = IERC20(vault).balanceOf(_user);
        assertGt(vaultSharesAfter, vaultSharesBefore, "User should have vault shares from final option");
        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio should be empty");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  7. FinalRewardsOption = IncreaseCollateral
    //     → Everything minus ZBF goes to collateral via swap
    // ═══════════════════════════════════════════════════════════════════════

    function testFinalOptionIncreaseCollateral() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.PayBalance, 0);
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral);

        uint256 remaining = rewardsAmount - _expectedZBF(); // 990 USDC
        uint256 swapOutputAmount = 990e18; // 990 AERO

        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);

        SwapMod.RouteParams[3] memory swapParams = _buildCollateralSwapParams(2, remaining, swapOutputAmount);
        _processRewardsWithSwap(swapParams);

        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        assertGt(uint256(uint128(lockedAfter.amount)), uint256(uint128(lockedBefore.amount)), "Lock should increase from final option");
        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio should be empty");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  8. FinalRewardsOption = PayToRecipient
    //     → Everything minus ZBF goes to recipient (same as PayBalance default)
    // ═══════════════════════════════════════════════════════════════════════

    function testFinalOptionPayToRecipient() public {
        _fundRewards();
        _configureRewardsOption(UserRewardsConfig.RewardsOption.PayBalance, 0);
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.PayToRecipient);

        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);
        _processRewards();

        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 expected = rewardsAmount - _expectedZBF();
        assertEq(recipientAfter - recipientBefore, expected, "Recipient gets everything minus ZBF");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  9. Combined: RewardsOption=InvestToVault(25%) + IncreaseCollateral(25%)
    //     + FinalOption=PayToRecipient
    //     → 25% vault, 25% collateral, rest to recipient
    // ═══════════════════════════════════════════════════════════════════════

    function testCombinedAllThreeSteps() public {
        _fundRewards();

        // Step 1: set rewards option = InvestToVault at 25%
        _configureRewardsOption(UserRewardsConfig.RewardsOption.InvestToVault, 25);
        // Step 2: set increase collateral at 25%
        _configureIncreaseCollateral(25);
        // Step 3: set final = PayToRecipient
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.PayToRecipient);

        address vault = ILoan(_loanContract)._vault();
        uint256 vaultSharesBefore = IERC20(vault).balanceOf(_user);
        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        uint256 vaultAmount = _postFeesAmount() * 25 / 100; // 25% of 990
        uint256 collateralAmount = _postFeesAmount() * 25 / 100; // 25% of 990

        // Build swap params: slot[1] for increase collateral in finalize
        SwapMod.RouteParams[3] memory swapParams = _buildCollateralSwapParams(1, collateralAmount, 247e18);
        _processRewardsWithSwap(swapParams);

        uint256 vaultSharesAfter = IERC20(vault).balanceOf(_user);
        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);

        // Vault should have received 25% of postFees
        assertGt(vaultSharesAfter, vaultSharesBefore, "Vault shares should increase");

        // Collateral should have increased
        assertGt(uint256(uint128(lockedAfter.amount)), uint256(uint128(lockedBefore.amount)), "Lock should increase");

        // Recipient gets: 990 - vault(247.5) - collateral(247.5) = 495
        uint256 expectedRecipient = _postFeesAmount() - vaultAmount - collateralAmount;
        assertEq(recipientAfter - recipientBefore, expectedRecipient, "Recipient gets remainder");

        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio should be empty");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  10. Combined: RewardsOption=IncreaseCollateral(25%) + IncreaseCollateral(25%)
    //      + FinalOption=InvestToVault
    //      → 25% collateral (step 3) + 25% collateral (step 4a) + rest to vault
    // ═══════════════════════════════════════════════════════════════════════

    function testCombinedDoubleCollateralPlusVault() public {
        _fundRewards();

        _configureRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 25);
        _configureIncreaseCollateral(25);
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.InvestToVault);

        address vault = ILoan(_loanContract)._vault();
        uint256 vaultSharesBefore = IERC20(vault).balanceOf(_user);
        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);

        uint256 amountInStep3 = _postFeesAmount() * 25 / 100; // 25% of 990
        uint256 amountInStep4a = _postFeesAmount() * 25 / 100; // 25% of 990
        uint256 swapOutputStep3 = 247e18;
        uint256 swapOutputStep4a = 247e18;

        // slot[0] for rewards option IncreaseCollateral, slot[1] for finalize IncreaseCollateral
        SwapMod.RouteParams[3] memory swapParams;
        swapParams[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: abi.encodeWithSelector(mockRouter.executeSwap.selector, rewardsToken, lockedAsset, amountInStep3, swapOutputStep3, _portfolioAccount),
            inputToken: rewardsToken,
            inputAmount: 0,
            outputToken: lockedAsset,
            minimumOutputAmount: 1
        });
        swapParams[1] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: abi.encodeWithSelector(mockRouter.executeSwap.selector, rewardsToken, lockedAsset, amountInStep4a, swapOutputStep4a, _portfolioAccount),
            inputToken: rewardsToken,
            inputAmount: 0,
            outputToken: lockedAsset,
            minimumOutputAmount: 1
        });

        _processRewardsWithSwap(swapParams);

        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 vaultSharesAfter = IERC20(vault).balanceOf(_user);

        // Collateral increased by both steps
        uint256 lockedIncrease = uint256(uint128(lockedAfter.amount)) - uint256(uint128(lockedBefore.amount));
        assertEq(lockedIncrease, swapOutputStep3 + swapOutputStep4a, "Lock should increase by both swap outputs");

        // Vault received the final remainder: 990 - 247.5 - 247.5 = 495
        assertGt(vaultSharesAfter, vaultSharesBefore, "Vault shares should increase from final option");

        assertEq(IERC20(rewardsToken).balanceOf(_portfolioAccount), 0, "Portfolio should be empty");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  11. Max percentages: RewardsOption=50% + IncreaseCollateral=50%
    //      → Nothing left for final option
    // ═══════════════════════════════════════════════════════════════════════

    function testMaxPercentagesLeaveNothingForFinal() public {
        _fundRewards();

        _configureRewardsOption(UserRewardsConfig.RewardsOption.InvestToVault, 50);
        _configureIncreaseCollateral(50);
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.PayToRecipient);

        address vault = ILoan(_loanContract)._vault();
        uint256 vaultSharesBefore = IERC20(vault).balanceOf(_user);
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        // 50% of postFees(990) = 495 for vault, 50% of 990 = 495 for collateral
        // 495 + 495 = 990 = postFees → nothing left for final
        uint256 collateralAmountIn = _postFeesAmount() * 50 / 100; // 495 USDC
        SwapMod.RouteParams[3] memory swapParams = _buildCollateralSwapParams(1, collateralAmountIn, 495e18);
        _processRewardsWithSwap(swapParams);

        uint256 vaultSharesAfter = IERC20(vault).balanceOf(_user);
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);

        // Vault got 50% of postFees = 495
        assertGt(vaultSharesAfter, vaultSharesBefore, "Vault shares should increase");

        // 50/50 on postFees splits evenly: 495 vault + 495 collateral = 990
        // Final remaining = 0, recipient gets 0
        assertEq(recipientAfter - recipientBefore, 0, "Recipient should get nothing when percentages use everything");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Validation Tests
    // ═══════════════════════════════════════════════════════════════════════

    function testRevertCumulativePercentagesExceed100() public {
        // Set rewards option percentage to 60%
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOptionPercentage.selector, 60);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Try to set increase collateral to 50% (60+50=110 > 100) → should revert
        vm.startPrank(_user);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setIncreaseCollateralPercentage.selector, 50);
        vm.expectRevert("Cumulative percentages exceed 100%");
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }

    function testRevertCumulativePercentagesExceed100Reverse() public {
        // Set increase collateral to 60%
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setIncreaseCollateralPercentage.selector, 60);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Try to set rewards option percentage to 50% (50+60=110 > 100) → should revert
        vm.startPrank(_user);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOptionPercentage.selector, 50);
        vm.expectRevert("Cumulative percentages exceed 100%");
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }

    function testCumulativePercentagesExactly100Succeeds() public {
        vm.startPrank(_user);
        address[] memory factories = new address[](2);
        factories[0] = address(_portfolioFactory);
        factories[1] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOptionPercentage.selector, 50);
        calls[1] = abi.encodeWithSelector(RewardsProcessingFacet.setIncreaseCollateralPercentage.selector, 50);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        assertEq(facet.getIncreaseCollateralPercentage(), 50);
    }

    function testRevertMatchingRewardsAndFinalOption() public {
        // Set rewards option to IncreaseCollateral
        _configureRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 0);

        // Try to set final to IncreaseCollateral too → should revert
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setFinalRewardsOption.selector, UserRewardsConfig.RewardsOption.IncreaseCollateral);
        vm.expectRevert("Final rewards option must differ from rewards option");
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }

    function testRevertMatchingFinalAndRewardsOption() public {
        // Set final to InvestToVault
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.InvestToVault);

        // Try to set rewards option to InvestToVault too → should revert
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOption.selector, UserRewardsConfig.RewardsOption.InvestToVault);
        vm.expectRevert("Rewards option must differ from final rewards option");
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }

    function testPayBalanceAllowedOnBothOptions() public {
        // Both default to PayBalance — setting one to PayBalance when other is PayBalance should succeed
        vm.startPrank(_user);
        address[] memory factories = new address[](2);
        factories[0] = address(_portfolioFactory);
        factories[1] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOption.selector, UserRewardsConfig.RewardsOption.PayBalance);
        calls[1] = abi.encodeWithSelector(RewardsProcessingFacet.setFinalRewardsOption.selector, UserRewardsConfig.RewardsOption.PayBalance);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        assertEq(uint256(facet.getRewardsOption()), uint256(UserRewardsConfig.RewardsOption.PayBalance));
        assertEq(uint256(facet.getFinalRewardsOption()), uint256(UserRewardsConfig.RewardsOption.PayBalance));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  With Debt: RewardsOption still works (capped at 25%), rest pays debt
    // ═══════════════════════════════════════════════════════════════════════

    function testWithDebtRewardsOptionCappedAt25() public {
        // Fund vault properly (deposit via ERC4626 so shares are minted)
        address funder = address(0xFEED);
        deal(_usdc, funder, 10000e6);
        vm.startPrank(funder);
        IERC20(_usdc).approve(_vault, 10000e6);
        IERC4626(_vault).deposit(10000e6, funder);
        vm.stopPrank();

        // Borrow to create debt
        borrowViaMulticall(500e6);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debtBefore, 0, "Should have debt");

        // Set InvestToVault at 50% — should be capped to 25% when debt > 0
        vm.startPrank(_user);
        address[] memory factories = new address[](2);
        factories[0] = address(_portfolioFactory);
        factories[1] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOption.selector, UserRewardsConfig.RewardsOption.InvestToVault);
        calls[1] = abi.encodeWithSelector(RewardsProcessingFacet.setRewardsOptionPercentage.selector, 50);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Verify capping
        uint256 effectivePercentage = facet.getRewardsOptionPercentage();
        assertEq(effectivePercentage, 25, "Should be capped to 25% when debt exists");

        // Fund and process
        deal(rewardsToken, _portfolioAccount, rewardsAmount);

        address vault = ILoan(_loanContract)._vault();
        uint256 vaultSharesBefore = IERC20(vault).balanceOf(_user);

        vm.prank(_authorizedCaller);
        SwapMod.RouteParams[3] memory noSwap;
        facet.processRewards(_tokenId, rewardsAmount, noSwap, 0);

        uint256 vaultSharesAfter = IERC20(vault).balanceOf(_user);
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();

        // Vault should have received shares (25% = 250 went to vault investment)
        assertGt(vaultSharesAfter, vaultSharesBefore, "Vault should get 25%");

        // Debt should have decreased (remaining went to debt)
        assertLt(debtAfter, debtBefore, "Debt should decrease");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  calculateRoutes tests
    // ═══════════════════════════════════════════════════════════════════════

    function testCalculateRoutesDefaultNoSwaps() public {
        // Default: PayBalance, no increase collateral, PayBalance final → no swaps
        RewardsProcessingFacet.SwapRoute[3] memory routes = facet.calculateRoutes(rewardsAmount, 0);
        assertEq(routes[0].inputAmount, 0, "Slot 0 should need no swap");
        assertEq(routes[1].inputAmount, 0, "Slot 1 should need no swap");
        assertEq(routes[2].inputAmount, 0, "Slot 2 should need no swap");
    }

    function testCalculateRoutesIncreaseCollateral25() public {
        _configureRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 25);

        RewardsProcessingFacet.SwapRoute[3] memory routes = facet.calculateRoutes(rewardsAmount, 0);

        uint256 expectedAmount = _postFeesAmount() * 25 / 100;
        assertEq(routes[0].inputToken, rewardsToken, "Slot 0 input should be rewards token");
        assertEq(routes[0].outputToken, lockedAsset, "Slot 0 output should be locked asset");
        assertEq(routes[0].inputAmount, expectedAmount, "Slot 0 amount should be 25% of postFees");
        assertEq(routes[1].inputAmount, 0, "Slot 1 should need no swap");
        assertEq(routes[2].inputAmount, 0, "Slot 2 should need no swap");
    }

    function testCalculateRoutesCombined() public {
        // InvestToVault 25% + IncreaseCollateral 25% + FinalOption = IncreaseCollateral
        _configureRewardsOption(UserRewardsConfig.RewardsOption.InvestToVault, 25);
        _configureIncreaseCollateral(25);
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral);

        RewardsProcessingFacet.SwapRoute[3] memory routes = facet.calculateRoutes(rewardsAmount, 0);

        uint256 vaultAmount = _postFeesAmount() * 25 / 100;
        uint256 collateralAmount = _postFeesAmount() * 25 / 100;
        uint256 finalAmount = _postFeesAmount() - vaultAmount - collateralAmount;

        // Slot 0: InvestToVault — rewardsToken == vault asset, so no swap needed
        assertEq(routes[0].inputAmount, 0, "Slot 0 no swap (same asset)");

        // Slot 1: IncreaseCollateral
        assertEq(routes[1].inputToken, rewardsToken, "Slot 1 input");
        assertEq(routes[1].outputToken, lockedAsset, "Slot 1 output");
        assertEq(routes[1].inputAmount, collateralAmount, "Slot 1 amount");

        // Slot 2: FinalOption = IncreaseCollateral
        assertEq(routes[2].inputToken, rewardsToken, "Slot 2 input");
        assertEq(routes[2].outputToken, lockedAsset, "Slot 2 output");
        assertEq(routes[2].inputAmount, finalAmount, "Slot 2 amount");
    }

    function testCalculateRoutesWithGasReclamation() public {
        _configureRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 50);

        uint256 gasAmount = 30e6; // 30 USDC gas
        RewardsProcessingFacet.SwapRoute[3] memory routes = facet.calculateRoutes(rewardsAmount, gasAmount);

        // 50% of postFees(990) = 495, but capped at remaining after gas (990 - 30 = 960)
        // 495 < 960 so no cap
        uint256 expectedAmount = _postFeesAmount() * 50 / 100;
        assertEq(routes[0].inputAmount, expectedAmount, "Amount should be 50% of postFees");
    }

    function testCalculateRoutesWithDebtOnlySlot0() public {
        // Fund vault properly and borrow to create debt
        address funder = address(0xFEED);
        deal(_usdc, funder, 10000e6);
        vm.startPrank(funder);
        IERC20(_usdc).approve(_vault, 10000e6);
        IERC4626(_vault).deposit(10000e6, funder);
        vm.stopPrank();
        borrowViaMulticall(500e6);

        _configureRewardsOption(UserRewardsConfig.RewardsOption.IncreaseCollateral, 15);
        _configureIncreaseCollateral(25);
        _configureFinalRewardsOption(UserRewardsConfig.RewardsOption.PayToRecipient);

        RewardsProcessingFacet.SwapRoute[3] memory routes = facet.calculateRoutes(rewardsAmount, 0);

        // With debt: protocol fee 5% + lender premium 20% = 25% fees
        // postFeesAmount = 750, capped percentage = 15%
        // Slot 0: 15% of 750 = 112.5
        assertGt(routes[0].inputAmount, 0, "Slot 0 should have swap");
        // Slots 1 and 2 are zero-balance only — should be empty with debt
        assertEq(routes[1].inputAmount, 0, "Slot 1 should be empty with debt");
        assertEq(routes[2].inputAmount, 0, "Slot 2 should be empty with debt");
    }

    // Helper
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();
    }
}
