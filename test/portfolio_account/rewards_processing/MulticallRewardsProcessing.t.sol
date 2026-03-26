// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title MulticallRewardsProcessing Tests
 * @notice Tests that RewardsProcessingFacet functions work correctly when called
 *         via FortyAcresPortfolioAccount.multicall() — the diamond's own batching
 *         function (NOT PortfolioManager.multicall).
 *
 * CONTEXT: A bug was found where RewardsProcessingFacet used external self-calls
 * like `ICollateralFacet(address(this)).getTotalDebt()`. When invoked through
 * the portfolio account's multicall, the reentrancy guard (set to ENTERED by
 * multicall) caused the fallback to revert on the external self-call. The fix
 * replaced external self-calls with direct library calls (CollateralManager.getTotalDebt()).
 *
 * These tests verify the fix by calling each affected function through the
 * portfolio account's multicall, which is the exact call path that was failing.
 */

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
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
import {FortyAcresPortfolioAccount} from "../../../src/accounts/FortyAcresPortfolioAccount.sol";

contract MulticallRewardsProcessingTest is Test, LocalSetup {
    RewardsProcessingFacet public rewardsProcessingFacet;
    MockOdosRouterRL public mockRouter;
    FortyAcresPortfolioAccount public portfolioAccountDiamond;

    address public rewardsToken; // USDC
    address public lockedAsset; // AERO (from voting escrow)
    uint256 public rewardsAmount = 1000e6; // 1000 USDC
    address public recipient = address(0x1234);

    function setUp() public override {
        super.setUp();

        // Deploy RewardsProcessingFacet
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_swapConfig), address(_ve), _vault);
        vm.stopPrank();

        // Initialize references
        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);
        portfolioAccountDiamond = FortyAcresPortfolioAccount(payable(_portfolioAccount));

        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        // Set up tokens
        rewardsToken = address(_usdc);
        lockedAsset = IVotingEscrow(_ve).token();

        // Set up UserRewardsConfig through PortfolioManager multicall
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](3);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        portfolioFactories[2] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](3);
        calldatas[0] = abi.encodeWithSelector(
            RewardsConfigFacet.setRewardsToken.selector,
            rewardsToken
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsConfigFacet.setRecipient.selector,
            recipient
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

    function setupRewards() internal {
        deal(rewardsToken, _portfolioAccount, rewardsAmount);
    }

    // Helper: add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseCollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper: borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseLendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: processRewards via portfolio multicall — zero debt
    //
    // This is the simplest regression test for the reentrancy guard bug.
    // processRewards internally calls CollateralManager.getTotalDebt() (was
    // previously an external self-call). Under multicall, the guard is set
    // to ENTERED, so any external call through the fallback would revert.
    // ═══════════════════════════════════════════════════════════════════════

    function test_processRewards_viaPortfolioMulticall_zeroDebt() public {
        setupRewards();

        // Verify initial state — no debt
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(totalDebt, 0, "Should have no debt initially");

        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);

        // Encode processRewards call
        SwapMod.RouteParams[4] memory noSwap;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.processRewards.selector,
            _tokenId,
            rewardsAmount,
            noSwap,
            uint256(0) // gas reclamation
        );

        // Call processRewards via the portfolio account's own multicall
        vm.prank(_authorizedCaller);
        portfolioAccountDiamond.multicall(data);

        // Verify rewards were processed: recipient receives rewards minus zero balance fee
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 zeroBalanceFee = _portfolioFactoryConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedRecipientAmount = rewardsAmount - feeAmount;

        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            expectedRecipientAmount,
            "Recipient should receive rewards minus zero balance fee via portfolio multicall"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 2: processRewards via portfolio multicall — with active debt
    //
    // When the portfolio has debt, processRewards follows the active-loan
    // branch: it reads getTotalDebt() twice (once to determine hasDebt, once
    // in _processActiveLoanRewards). This was the primary failure scenario.
    // ═══════════════════════════════════════════════════════════════════════

    function test_processRewards_viaPortfolioMulticall_withActiveDebt() public {
        // Set up collateral and borrow to create debt
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 500e6;

        // Fund vault for borrowing
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000;
        deal(address(_usdc), vault, vaultBalance);

        borrowViaMulticall(borrowAmount);

        // Verify debt exists
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt after borrowing");

        // Fund portfolio with USDC for rewards processing
        address loanAsset = ILoan(_loanContract)._asset();
        deal(loanAsset, _portfolioAccount, rewardsAmount);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        // Encode processRewards call
        SwapMod.RouteParams[4] memory noSwap;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.processRewards.selector,
            _tokenId,
            rewardsAmount,
            noSwap,
            uint256(0)
        );

        // Call via portfolio account's own multicall — this was the failing path
        vm.prank(_authorizedCaller);
        portfolioAccountDiamond.multicall(data);

        // Verify debt was reduced
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfter, debtBefore, "Debt should decrease after processRewards via multicall");

        // Calculate expected fees (protocol fee + lender premium are taken on active loans)
        uint256 protocolFee = (rewardsAmount * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewardsAmount * _loanConfig.getLenderPremium()) / 10000;
        uint256 amountForDebt = rewardsAmount - protocolFee - lenderPremium;

        uint256 expectedDebt = debtBefore > amountForDebt ? debtBefore - amountForDebt : 0;
        assertEq(debtAfter, expectedDebt, "Debt should be decreased by rewards minus fees");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: swapToRewardsTokenMultiple + processRewards batched via
    //         portfolio multicall
    //
    // This simulates the exact on-chain flow that was failing: the authorized
    // caller batches a swap + processRewards in a single multicall on the
    // portfolio account. Both functions internally read getTotalDebt().
    // ═══════════════════════════════════════════════════════════════════════

    function test_swapThenProcessRewards_batchedViaPortfolioMulticall() public {
        // Set up: create a second token that needs swapping to USDC
        MockOdosRouterRL router = mockRouter;
        address inputToken = address(new MockERC20ForTest("Reward Token", "RWD", 18));
        uint256 inputAmount = 100e18;
        uint256 swapOutputAmount = 500e6; // Will produce 500 USDC from swap

        // Fund portfolio with the input token
        deal(inputToken, _portfolioAccount, inputAmount);
        // Fund portfolio with additional USDC (simulating already-claimed USDC rewards)
        deal(rewardsToken, _portfolioAccount, 500e6);

        // Fund mock router with USDC for the swap output
        deal(rewardsToken, address(router), swapOutputAmount);

        // Build swap data for the mock router
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            inputToken,
            rewardsToken,
            inputAmount,
            swapOutputAmount,
            _portfolioAccount
        );

        // Build swapToRewardsTokenMultiple params
        SwapMod.RouteParams[] memory swapParams = new SwapMod.RouteParams[](1);
        swapParams[0] = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(router),
            swapData: swapData,
            inputToken: inputToken,
            inputAmount: inputAmount,
            outputToken: address(0), // ignored by swapToRewardsTokenMultiple
            minimumOutputAmount: 0
        });

        // Build processRewards params — total rewards = 500 (existing) + 500 (from swap) = 1000 USDC
        SwapMod.RouteParams[4] memory noSwap;

        // Batch both calls into portfolio multicall
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.swapToRewardsTokenMultiple.selector,
            swapParams
        );
        data[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.processRewards.selector,
            _tokenId,
            rewardsAmount, // 1000 USDC
            noSwap,
            uint256(0)
        );

        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);

        // Execute the batch via portfolio account's multicall
        vm.prank(_authorizedCaller);
        portfolioAccountDiamond.multicall(data);

        // Verify: recipient should have received rewards (minus zero balance fee)
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 zeroBalanceFee = _portfolioFactoryConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedRecipientAmount = rewardsAmount - feeAmount;

        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            expectedRecipientAmount,
            "Batched swap+processRewards via portfolio multicall should succeed"
        );

        // Verify portfolio's input token was consumed by swap
        assertEq(
            IERC20(inputToken).balanceOf(_portfolioAccount),
            0,
            "Input token should be fully consumed by swap"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 4: getRewardsToken via portfolio multicall
    //
    // getRewardsToken is a view function that internally calls
    // CollateralManager.getTotalDebt(). Verify it works via multicall.
    // Note: multicall is not view, so the return value is ABI-encoded.
    // ═══════════════════════════════════════════════════════════════════════

    function test_getRewardsToken_viaPortfolioMulticall() public {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.getRewardsToken.selector
        );

        // Call via portfolio multicall — would revert with the old external self-call
        vm.prank(_authorizedCaller);
        bytes[] memory results = portfolioAccountDiamond.multicall(data);

        // Decode the result
        address returnedToken = abi.decode(results[0], (address));

        // With no debt, should return the configured rewards token (USDC)
        assertEq(returnedToken, rewardsToken, "getRewardsToken via multicall should return USDC");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 5: calculateRoutes via portfolio multicall
    //
    // calculateRoutes is a view function that internally calls
    // CollateralManager.getTotalDebt(). Verify it works via multicall.
    // ═══════════════════════════════════════════════════════════════════════

    function test_calculateRoutes_viaPortfolioMulticall() public {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.calculateRoutes.selector,
            _tokenId,
            rewardsAmount,
            uint256(0) // gas reclamation
        );

        // Call via portfolio multicall
        vm.prank(_authorizedCaller);
        bytes[] memory results = portfolioAccountDiamond.multicall(data);

        // Decode the result — should be a SwapRoute[4]
        RewardsProcessingFacet.SwapRoute[4] memory routes = abi.decode(
            results[0],
            (RewardsProcessingFacet.SwapRoute[4])
        );

        // With zero debt and no zero-balance distribution entries, all routes should be empty
        for (uint256 i = 0; i < 4; i++) {
            assertEq(routes[i].inputAmount, 0, "Route should have zero input amount (no distributions configured)");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 6: calculateRoutes via portfolio multicall — with active debt
    //
    // Ensures the hasDebt branch in calculateRoutes also works when called
    // through the portfolio multicall with the reentrancy guard active.
    // ═══════════════════════════════════════════════════════════════════════

    function test_calculateRoutes_viaPortfolioMulticall_withDebt() public {
        // Set up debt
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 200e6;
        address vault = ILoan(_loanContract)._vault();
        deal(address(_usdc), vault, (borrowAmount * 10000) / 8000);
        borrowViaMulticall(borrowAmount);

        // Verify debt exists
        assertGt(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Should have debt");

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.calculateRoutes.selector,
            _tokenId,
            rewardsAmount,
            uint256(0)
        );

        // Call via portfolio multicall — exercises the hasDebt=true branch
        vm.prank(_authorizedCaller);
        bytes[] memory results = portfolioAccountDiamond.multicall(data);

        // Should not revert. Decode and verify structure.
        RewardsProcessingFacet.SwapRoute[4] memory routes = abi.decode(
            results[0],
            (RewardsProcessingFacet.SwapRoute[4])
        );

        // With debt but no active balance distribution, all routes should be empty
        for (uint256 i = 0; i < 4; i++) {
            assertEq(routes[i].inputAmount, 0, "Route should have zero input with debt but no active balance distribution");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 7: getRewardsToken via portfolio multicall — with active debt
    //
    // When there is debt, getRewardsToken should return the vault asset
    // (not the user-configured rewards token). Verify this branch works
    // through multicall.
    // ═══════════════════════════════════════════════════════════════════════

    function test_getRewardsToken_viaPortfolioMulticall_withDebt() public {
        // Set up debt
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 200e6;
        address vault = ILoan(_loanContract)._vault();
        deal(address(_usdc), vault, (borrowAmount * 10000) / 8000);
        borrowViaMulticall(borrowAmount);

        assertGt(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Should have debt");

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.getRewardsToken.selector
        );

        vm.prank(_authorizedCaller);
        bytes[] memory results = portfolioAccountDiamond.multicall(data);

        address returnedToken = abi.decode(results[0], (address));

        // With debt, should always return vault asset (USDC) regardless of user config
        assertEq(returnedToken, rewardsToken, "getRewardsToken with debt via multicall should return vault asset");
    }
}

// Minimal ERC20 for the swap input token in test 3
contract MockERC20ForTest {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}
