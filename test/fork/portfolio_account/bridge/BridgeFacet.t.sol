// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BridgeFacet} from "../../../../src/facets/account/bridge/BridgeFacet.sol";
import {DeployBridgeFacet} from "../../../../script/portfolio_account/facets/DeployBridgeFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {SwapMod} from "../../../../src/facets/account/swap/SwapMod.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";

/**
 * @dev Subclass that blocks specified tokens via the `_isSwapAllowed` override.
 *      Used in `test_swapMultiple_skipsBlockedTokens` to verify the hook is honored.
 *
 *      The blocklist is read from a deterministic storage slot to keep things
 *      simple under the diamond delegatecall pattern. We expose a setter that
 *      can be invoked by anyone for test convenience.
 */
contract BlockingBridgeFacet is BridgeFacet {
    // ERC-7201-style slot for the blocklist mapping
    bytes32 private constant BLOCKLIST_SLOT = keccak256("test.BlockingBridgeFacet.blocklist");

    constructor(address portfolioFactory, address token, address tokenMessenger, uint32 destinationDomain, address swapConfig)
        BridgeFacet(portfolioFactory, token, tokenMessenger, destinationDomain, swapConfig)
    {}

    function setBlocked(address token, bool blocked) external {
        bytes32 slot = keccak256(abi.encode(token, BLOCKLIST_SLOT));
        assembly { sstore(slot, blocked) }
    }

    function isBlocked(address token) external view returns (bool result) {
        bytes32 slot = keccak256(abi.encode(token, BLOCKLIST_SLOT));
        assembly { result := sload(slot) }
    }

    function _isSwapAllowed(address inputToken) internal view override returns (bool) {
        bytes32 slot = keccak256(abi.encode(inputToken, BLOCKLIST_SLOT));
        uint256 blocked;
        assembly { blocked := sload(slot) }
        return blocked == 0;
    }
}

/**
 * @dev Mock swap target that pulls `inputAmount` of the input token from
 *      the caller and transfers a pre-configured `outputAmount` of the
 *      output token back. Mirrors the real swap flow that `SwapMod.swap`
 *      expects (pre-approval + transferFrom + push output to caller).
 */
contract MockSwapTarget {
    IERC20 public immutable outputToken;

    constructor(address _outputToken) {
        outputToken = IERC20(_outputToken);
    }

    /// @notice Pull `inputAmount` of `inputToken` from caller and send `outputAmount` of outputToken back.
    function swap(address inputToken, uint256 inputAmount, uint256 outputAmount) external {
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        require(outputToken.transfer(msg.sender, outputAmount), "transfer failed");
    }
}

/// @dev Swap target that always reverts. Used to drive the `SwapFailed` branch.
contract RevertingSwapTarget {
    function swap(address, uint256, uint256) external pure {
        revert("boom");
    }
}

contract BridgeFacetTest is Test {
    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    FacetRegistry public _facetRegistry;
    PortfolioFactoryConfig public _portfolioFactoryConfig;
    VotingConfig public _votingConfig;
    LoanConfig public _loanConfig;
    SwapConfig public _swapConfig;
    BridgeFacet public _bridgeFacet;
    IERC20 public _usdc;

    address public constant FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant INK_USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant USDC_SOURCE = 0xd3abC2b515345E47D41C0A1Cd64F8493B80d1ad6;
    address public _authorizedCaller = address(0xaaaaa);
    address public _user = address(0x1234);
    address public _portfolioAccount;
    uint256 public constant BRIDGE_AMOUNT = 100e6; // 100 USDC

    // Re-declare for vm.expectEmit topic matching.
    event SwapFailed(uint256 inputAmount, address indexed inputToken, address outputToken, address indexed owner);

    function setUp() public {
        // Fork Ink chain
        uint256 fork = vm.createFork(vm.envString("INK_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(30768635);

        // Use real USDC contract
        _usdc = IERC20(INK_USDC);

        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Deploy PortfolioManager and Factory
        _portfolioManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (_portfolioFactory, _facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("velodrome-usdc")))
        );

        // Deploy config contracts
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy(address(_portfolioFactory), FORTY_ACRES_DEPLOYER);

        // Deploy BridgeFacet
        DeployBridgeFacet bridgeDeployer = new DeployBridgeFacet();
        bridgeDeployer.deploy(
            address(_portfolioFactory),
            INK_USDC,
            TOKEN_MESSENGER,
            address(_swapConfig)
        );

        // Get the deployed BridgeFacet address from the registry
        bytes4 bridgeSelector = BridgeFacet.bridge.selector;
        address bridgeFacetAddress = _facetRegistry.getFacetForSelector(bridgeSelector);
        _bridgeFacet = BridgeFacet(bridgeFacetAddress);

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        // Create a portfolio account
        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Transfer USDC from source address to portfolio account
        vm.prank(USDC_SOURCE);
        _usdc.transfer(_portfolioAccount, BRIDGE_AMOUNT);

        // Approve TokenMessenger to spend USDC from portfolio account
        vm.prank(_portfolioAccount);
        _usdc.approve(TOKEN_MESSENGER, type(uint256).max);
    }

    function testBridgeFacetDeployment() public {
        assertEq(address(_bridgeFacet._portfolioFactory()), address(_portfolioFactory));
        assertEq(address(_bridgeFacet._token()), INK_USDC);
        assertEq(address(_bridgeFacet._tokenMessenger()), TOKEN_MESSENGER);
        assertEq(_bridgeFacet._destinationDomain(), 2); // Optimism Mainnet
    }

    function testBridge() public {
        uint256 balanceBefore = _usdc.balanceOf(_portfolioAccount);
        assertEq(balanceBefore, BRIDGE_AMOUNT);

        vm.prank(_authorizedCaller);
        BridgeFacet(_portfolioAccount).bridge(BRIDGE_AMOUNT, 0);

        // Verify USDC was transferred/burned by TokenMessenger
        uint256 balanceAfter = _usdc.balanceOf(_portfolioAccount);
        assertEq(balanceAfter, 0, "All USDC should be bridged");
    }

    // ---------------------------------------------------------------------
    //                           swapMultiple tests
    // ---------------------------------------------------------------------

    /// @dev Helper: deploy a mock swap target, whitelist it on SwapConfig, and fund it with USDC.
    function _deployAndFundMockTarget(uint256 usdcFunding) internal returns (MockSwapTarget target) {
        target = new MockSwapTarget(INK_USDC);
        // Whitelist on SwapConfig. Owner is determined by the deploy script — resolve dynamically.
        _whitelistTarget(address(target));
        // Fund the target with USDC so it can pay out swaps.
        vm.prank(USDC_SOURCE);
        _usdc.transfer(address(target), usdcFunding);
    }

    function _whitelistTarget(address target) internal {
        address owner = _swapConfig.owner();
        vm.prank(owner);
        _swapConfig.setApprovedSwapTarget(target, true);
    }

    /// @dev Helper: build a RouteParams entry for a mock swap.
    function _route(address swapTarget, address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 minimumOutput)
        internal
        view
        returns (SwapMod.RouteParams memory)
    {
        return SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: swapTarget,
            swapData: abi.encodeWithSelector(MockSwapTarget.swap.selector, inputToken, inputAmount, outputAmount),
            inputToken: inputToken,
            inputAmount: inputAmount,
            outputToken: INK_USDC,
            minimumOutputAmount: minimumOutput
        });
    }

    /// @dev Mints a mock token and funds the portfolio account with it.
    function _mintInputTokenTo(address to, uint256 amount, string memory name) internal returns (MockERC20 token) {
        token = new MockERC20(name, name, 18);
        token.mint(to, amount);
    }

    /// @notice Happy path: multiple routes succeed, returned `amount` equals the sum of outputs.
    function test_swapMultiple_happyPath_accumulatesOutputs() public {
        MockSwapTarget target = _deployAndFundMockTarget(1_000e6);
        MockERC20 tokenA = _mintInputTokenTo(_portfolioAccount, 10e18, "TKA");
        MockERC20 tokenB = _mintInputTokenTo(_portfolioAccount, 20e18, "TKB");

        uint256 outA = 30e6;
        uint256 outB = 50e6;

        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](2);
        routes[0] = _route(address(target), address(tokenA), 10e18, outA, outA);
        routes[1] = _route(address(target), address(tokenB), 20e18, outB, outB);

        uint256 usdcBefore = _usdc.balanceOf(_portfolioAccount);

        vm.prank(_authorizedCaller);
        uint256 amount = BridgeFacet(_portfolioAccount).swapMultiple(routes);

        assertEq(amount, outA + outB, "returned amount should be sum of outputs");
        assertEq(_usdc.balanceOf(_portfolioAccount), usdcBefore + outA + outB, "USDC balance should grow by total output");
        assertEq(tokenA.balanceOf(_portfolioAccount), 0, "tokenA fully consumed");
        assertEq(tokenB.balanceOf(_portfolioAccount), 0, "tokenB fully consumed");
    }

    /// @notice An entry whose inputToken == USDC is skipped: contributes 0, never attempted.
    ///         Other entries in the same batch still process.
    function test_swapMultiple_skipsUsdcInput_butProcessesOthers() public {
        MockSwapTarget target = _deployAndFundMockTarget(1_000e6);
        MockERC20 tokenA = _mintInputTokenTo(_portfolioAccount, 5e18, "TKA");

        uint256 outA = 40e6;

        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](2);
        // First entry: input is USDC — must be skipped before SwapMod.swap is invoked.
        // We use a clearly-invalid swap target / swapData; if the code path is hit
        // it will revert, surfacing the bug (skip not honored).
        routes[0] = SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: address(0xdead),
            swapData: hex"deadbeef",
            inputToken: INK_USDC,
            inputAmount: BRIDGE_AMOUNT,
            outputToken: INK_USDC,
            minimumOutputAmount: 0
        });
        routes[1] = _route(address(target), address(tokenA), 5e18, outA, outA);

        uint256 usdcBefore = _usdc.balanceOf(_portfolioAccount);

        vm.prank(_authorizedCaller);
        uint256 amount = BridgeFacet(_portfolioAccount).swapMultiple(routes);

        assertEq(amount, outA, "USDC entry should contribute 0");
        // USDC balance grew only by outA (the second route's output). The skipped USDC
        // entry should NOT have moved USDC anywhere.
        assertEq(_usdc.balanceOf(_portfolioAccount), usdcBefore + outA, "only second route's USDC added");
        assertEq(tokenA.balanceOf(_portfolioAccount), 0, "tokenA consumed");
    }

    /// @notice Entries blocked by `_isSwapAllowed` are skipped entirely and contribute 0.
    ///         Verified by replacing BridgeFacet with BlockingBridgeFacet, which overrides the hook.
    function test_swapMultiple_skipsBlockedTokens() public {
        // Deploy a subclass that blocks specific tokens, and replace the registered facet.
        BlockingBridgeFacet blockingFacet = new BlockingBridgeFacet(
            address(_portfolioFactory),
            INK_USDC,
            TOKEN_MESSENGER,
            2,
            address(_swapConfig)
        );

        // Replace the registered BridgeFacet. Same selectors as DeployBridgeFacet.getSelectorsForFacet().
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = BridgeFacet.bridge.selector;
        selectors[1] = BridgeFacet.swapMultiple.selector;
        selectors[2] = BlockingBridgeFacet.setBlocked.selector;

        vm.prank(FORTY_ACRES_DEPLOYER);
        _facetRegistry.replaceFacet(address(_bridgeFacet), address(blockingFacet), selectors, "BlockingBridgeFacet");

        MockSwapTarget target = _deployAndFundMockTarget(1_000e6);
        MockERC20 tokenA = _mintInputTokenTo(_portfolioAccount, 5e18, "TKA");
        MockERC20 tokenB = _mintInputTokenTo(_portfolioAccount, 7e18, "TKB");

        // Block tokenA. The setter writes to the *portfolio account's* storage via delegatecall.
        BlockingBridgeFacet(_portfolioAccount).setBlocked(address(tokenA), true);

        uint256 outB = 44e6;

        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](2);
        // Blocked entry — uses an invalid swap target so we can prove the route was skipped
        // pre-swap. If the skip wasn't honored, SwapMod.swap would call 0xdead and revert,
        // surfacing a SwapFailed event (which would also break the assertion below).
        routes[0] = SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: address(0xdead),
            swapData: hex"feed",
            inputToken: address(tokenA),
            inputAmount: 5e18,
            outputToken: INK_USDC,
            minimumOutputAmount: 0
        });
        routes[1] = _route(address(target), address(tokenB), 7e18, outB, outB);

        uint256 usdcBefore = _usdc.balanceOf(_portfolioAccount);

        // The blocked route must NOT emit SwapFailed (it should be skipped before the try block).
        // We record logs and assert no SwapFailed topic appears.
        vm.recordLogs();

        vm.prank(_authorizedCaller);
        uint256 amount = BlockingBridgeFacet(_portfolioAccount).swapMultiple(routes);

        // Blocked route must have contributed nothing — its input token is untouched
        // and no USDC came in from it.
        assertEq(amount, outB, "blocked token contributes 0");
        assertEq(_usdc.balanceOf(_portfolioAccount), usdcBefore + outB);
        assertEq(tokenA.balanceOf(_portfolioAccount), 5e18, "blocked tokenA untouched");
        assertEq(tokenB.balanceOf(_portfolioAccount), 0, "tokenB consumed");

        // Confirm no SwapFailed event was emitted — proves the route was skipped entirely
        // (not attempted-then-failed).
        bytes32 swapFailedTopic = keccak256("SwapFailed(uint256,address,address,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != swapFailedTopic, "blocked route should not emit SwapFailed");
            }
        }
    }

    /// @notice A failing route emits SwapFailed(inputAmount, inputToken, USDC, owner) and the batch continues.
    function test_swapMultiple_failingRouteEmitsEventAndContinues() public {
        MockSwapTarget goodTarget = _deployAndFundMockTarget(1_000e6);
        RevertingSwapTarget badTarget = new RevertingSwapTarget();
        _whitelistTarget(address(badTarget));

        MockERC20 tokenA = _mintInputTokenTo(_portfolioAccount, 3e18, "TKA");
        MockERC20 tokenB = _mintInputTokenTo(_portfolioAccount, 9e18, "TKB");

        uint256 outB = 60e6;

        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](2);
        // First entry routes through the reverting target.
        routes[0] = _route(address(badTarget), address(tokenA), 3e18, 1, 1);
        // Second entry succeeds.
        routes[1] = _route(address(goodTarget), address(tokenB), 9e18, outB, outB);

        uint256 usdcBefore = _usdc.balanceOf(_portfolioAccount);

        // Expect the SwapFailed event for the first route. inputToken is indexed,
        // owner is indexed; check both topics + data. emitter is the portfolio account
        // (the diamond proxy), since SwapMod.swap is delegatecalled.
        vm.expectEmit(true, true, true, true, _portfolioAccount);
        emit SwapFailed(3e18, address(tokenA), INK_USDC, _user);

        vm.prank(_authorizedCaller);
        uint256 amount = BridgeFacet(_portfolioAccount).swapMultiple(routes);

        // Batch continued — second route's USDC was credited.
        assertEq(amount, outB, "only successful route contributes");
        assertEq(_usdc.balanceOf(_portfolioAccount), usdcBefore + outB);
        // Failing route did NOT spend the input — SwapMod reverted before transferFrom,
        // or even if it transferred, the revert rolled back the sub-call. tokenA balance unchanged.
        assertEq(tokenA.balanceOf(_portfolioAccount), 3e18, "failing route rolled back");
        assertEq(tokenB.balanceOf(_portfolioAccount), 0, "successful route consumed input");
    }

    /// @notice Unauthorized callers cannot invoke swapMultiple.
    function testRevert_swapMultiple_unauthorizedCaller() public {
        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](0);

        vm.prank(address(0xbeef));
        vm.expectRevert(); // AccessControl.NotAuthorizedCaller selector
        BridgeFacet(_portfolioAccount).swapMultiple(routes);
    }

    /// @notice Even the portfolio owner is not an authorized caller (auth is the global PM list, not ownership).
    function testRevert_swapMultiple_portfolioOwnerNotAuthorized() public {
        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](0);

        vm.prank(_user);
        vm.expectRevert();
        BridgeFacet(_portfolioAccount).swapMultiple(routes);
    }

    /// @notice Empty input array returns 0 and is a no-op (no balance changes, no events).
    function test_swapMultiple_emptyArray_noOp() public {
        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](0);

        uint256 usdcBefore = _usdc.balanceOf(_portfolioAccount);

        vm.prank(_authorizedCaller);
        uint256 amount = BridgeFacet(_portfolioAccount).swapMultiple(routes);

        assertEq(amount, 0, "empty batch returns 0");
        assertEq(_usdc.balanceOf(_portfolioAccount), usdcBefore, "balance unchanged");
    }

    /// @notice A batch composed entirely of USDC inputs returns 0 without touching balances.
    function test_swapMultiple_allUsdcInputs_returnsZero() public {
        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            routes[i] = SwapMod.RouteParams({
                swapConfig: address(_swapConfig),
                swapTarget: address(0xdead),
                swapData: hex"00",
                inputToken: INK_USDC,
                inputAmount: 1e6,
                outputToken: INK_USDC,
                minimumOutputAmount: 0
            });
        }
        uint256 usdcBefore = _usdc.balanceOf(_portfolioAccount);

        vm.prank(_authorizedCaller);
        uint256 amount = BridgeFacet(_portfolioAccount).swapMultiple(routes);

        assertEq(amount, 0);
        assertEq(_usdc.balanceOf(_portfolioAccount), usdcBefore);
    }

    /// @notice Each successful swap emits SwapMod.SwapExecuted as well — sanity check that
    ///         the success path actually exercises the real SwapMod logic, not just an early return.
    function test_swapMultiple_successfulSwapEmitsSwapExecuted() public {
        MockSwapTarget target = _deployAndFundMockTarget(1_000e6);
        MockERC20 tokenA = _mintInputTokenTo(_portfolioAccount, 2e18, "TKA");

        uint256 outA = 25e6;

        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](1);
        routes[0] = _route(address(target), address(tokenA), 2e18, outA, outA);

        // We only care that *some* SwapExecuted is emitted with the right indexed args.
        // SwapMod emits: event SwapExecuted(address indexed swapTarget, address indexed inputToken, uint256 inputAmount, address indexed outputToken, uint256 outputAmount)
        vm.expectEmit(true, true, true, true, _portfolioAccount);
        emit SwapMod.SwapExecuted(address(target), address(tokenA), 2e18, INK_USDC, outA);

        vm.prank(_authorizedCaller);
        BridgeFacet(_portfolioAccount).swapMultiple(routes);
    }

    /// @notice If a route would produce less than `minimumOutputAmount` of USDC,
    ///         SwapMod reverts with "Slippage exceeded" — this is a route failure,
    ///         so the batch should emit SwapFailed and continue, not bubble the revert.
    function test_swapMultiple_slippageFailureBecomesSwapFailedEvent() public {
        MockSwapTarget target = _deployAndFundMockTarget(1_000e6);
        MockERC20 tokenA = _mintInputTokenTo(_portfolioAccount, 1e18, "TKA");

        // Target will deliver only 5 USDC, but we set minimumOutputAmount higher.
        uint256 actualOut = 5e6;
        uint256 demandedOut = 50e6;

        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](1);
        routes[0] = _route(address(target), address(tokenA), 1e18, actualOut, demandedOut);

        vm.expectEmit(true, true, true, true, _portfolioAccount);
        emit SwapFailed(1e18, address(tokenA), INK_USDC, _user);

        vm.prank(_authorizedCaller);
        uint256 amount = BridgeFacet(_portfolioAccount).swapMultiple(routes);

        assertEq(amount, 0, "slippage failure contributes 0");
    }

    /// @notice A route whose swapTarget is not whitelisted on SwapConfig also becomes
    ///         a SwapFailed event (SwapMod reverts with NotApprovedSwapTarget). The batch continues.
    function test_swapMultiple_unwhitelistedTargetBecomesSwapFailedEvent() public {
        MockSwapTarget approved = _deployAndFundMockTarget(1_000e6);
        // Note: deploy a second target but do NOT whitelist it.
        MockSwapTarget unapproved = new MockSwapTarget(INK_USDC);
        vm.prank(USDC_SOURCE);
        _usdc.transfer(address(unapproved), 100e6);

        MockERC20 tokenA = _mintInputTokenTo(_portfolioAccount, 1e18, "TKA");
        MockERC20 tokenB = _mintInputTokenTo(_portfolioAccount, 2e18, "TKB");

        uint256 outB = 10e6;

        SwapMod.RouteParams[] memory routes = new SwapMod.RouteParams[](2);
        routes[0] = _route(address(unapproved), address(tokenA), 1e18, 5e6, 1);
        routes[1] = _route(address(approved), address(tokenB), 2e18, outB, outB);

        vm.expectEmit(true, true, true, true, _portfolioAccount);
        emit SwapFailed(1e18, address(tokenA), INK_USDC, _user);

        vm.prank(_authorizedCaller);
        uint256 amount = BridgeFacet(_portfolioAccount).swapMultiple(routes);

        assertEq(amount, outB, "only the approved route contributes");
        assertEq(tokenA.balanceOf(_portfolioAccount), 1e18, "unapproved route did not spend tokenA");
    }
}
