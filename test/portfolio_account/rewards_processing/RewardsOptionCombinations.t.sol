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
 * @dev Tests for zero-balance and active-balance distribution entry combinations.
 *
 * Zero-balance flow (no debt):
 *   1. Zero balance fee
 *   2. Gas reclamation
 *   3. DistributionEntry array (up to 4 entries, each with percentage of postFeesAmount)
 *   4. Remainder → default recipient
 *
 * Active-balance flow (has debt):
 *   1. Protocol fee + lender premium
 *   2. Gas reclamation
 *   3. Single DistributionEntry (up to 25% of postFeesAmount)
 *   4. Remainder → debt repayment → excess to vault
 */
contract RewardsOptionCombinationsTest is Test, LocalSetup {
    RewardsProcessingFacet public rewardsProcessingFacet;
    MockOdosRouterRL public mockRouter;

    address public rewardsToken;
    address public lockedAsset;
    uint256 public rewardsAmount = 1000e6;
    address public recipient = address(0x1234);

    function setUp() public override {
        super.setUp();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_swapConfig), address(_ve), _vault);
        vm.stopPrank();

        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        rewardsToken = address(_usdc);
        lockedAsset = IVotingEscrow(_ve).token();

        // Basic setup: set rewards token and recipient
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](3);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        portfolioFactories[2] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](3);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            rewardsToken
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRecipient.selector,
            recipient
        );
        calldatas[2] = abi.encodeWithSelector(
            BaseCollateralFacet.addCollateral.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();
    }

    function setupRewards() internal {
        deal(rewardsToken, _portfolioAccount, rewardsAmount);
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

    // ─── Zero-Balance Distribution Tests ──────────────────────────────

    function testZeroBalanceSinglePayToRecipient() public {
        setupRewards();

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.PayToRecipient,
            percentage: 100,
            outputToken: address(0),
            target: recipient
        });
        _setZeroBalanceDistribution(entries);

        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

        vm.startPrank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(_tokenId, rewardsAmount, noSwap, 0);
        vm.stopPrank();

        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expected = rewardsAmount - feeAmount;

        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);
        assertEq(recipientAfter - recipientBefore, expected, "Recipient should receive 100% of post-fees amount");
    }

    function testZeroBalanceIncreaseCollateral() public {
        setupRewards();

        // Fund mock router
        deal(lockedAsset, address(mockRouter), 500e18);

        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 50,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 postFeesAmount = rewardsAmount - feeAmount;
        uint256 amountToSwap = postFeesAmount * 50 / 100;
        uint256 expectedLockedAssetOut = 500e18;

        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            rewardsToken, lockedAsset, amountToSwap, expectedLockedAssetOut, _portfolioAccount
        );
        vm.prank(_portfolioAccount);
        IERC20(rewardsToken).approve(address(mockRouter), amountToSwap);

        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);
        uint256 lockedAmountBefore = uint256(uint128(lockedBefore.amount));
        uint256 recipientBefore = IERC20(rewardsToken).balanceOf(recipient);

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

        // Verify collateral increased
        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 lockedAmountAfter = uint256(uint128(lockedAfter.amount));
        assertGe(lockedAmountAfter, lockedAmountBefore + expectedLockedAssetOut, "Collateral should increase");

        // Verify remainder went to recipient (50% of post-fees)
        uint256 recipientAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 remainingRewards = postFeesAmount - amountToSwap;
        assertEq(recipientAfter - recipientBefore, remainingRewards, "Recipient should receive remaining 50%");
    }

    function testCalculateRoutesZeroBalance() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = UserRewardsConfig.DistributionEntry({
            option: UserRewardsConfig.RewardsOption.IncreaseCollateral,
            percentage: 50,
            outputToken: address(0),
            target: address(0)
        });
        _setZeroBalanceDistribution(entries);

        RewardsProcessingFacet.SwapRoute[4] memory routes = rewardsProcessingFacet.calculateRoutes(rewardsAmount, 0);

        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 postFeesAmount = rewardsAmount - feeAmount;
        uint256 expectedSwapAmount = postFeesAmount * 50 / 100;

        assertEq(routes[0].inputToken, rewardsToken, "Should swap from rewards token");
        assertEq(routes[0].outputToken, lockedAsset, "Should swap to locked asset");
        assertEq(routes[0].inputAmount, expectedSwapAmount, "Should swap 50% of post-fees");
        assertEq(routes[1].inputAmount, 0, "Slot 1 should be empty");
    }

    function testCalculateRoutesDefaultNoSwaps() public view {
        // No distribution set, no debt — all routes should be empty
        RewardsProcessingFacet.SwapRoute[4] memory routes = rewardsProcessingFacet.calculateRoutes(rewardsAmount, 0);
        assertEq(routes[0].inputAmount, 0, "No swaps needed");
        assertEq(routes[1].inputAmount, 0, "No swaps needed");
        assertEq(routes[2].inputAmount, 0, "No swaps needed");
        assertEq(routes[3].inputAmount, 0, "No swaps needed");
    }
}
