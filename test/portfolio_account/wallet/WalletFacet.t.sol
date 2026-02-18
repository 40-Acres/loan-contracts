// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {Setup} from "../utils/Setup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract WalletFacetTest is Test, Setup {
    WalletFacet public walletFacet;
    MockOdosRouterRL public mockRouter;

    // Wallet-specific state
    PortfolioFactory public _walletFactory;
    FacetRegistry public _walletFacetRegistry;
    address public _walletPortfolio;
    SwapConfig public _walletSwapConfig;

    address public inputToken; // USDC
    address public outputToken; // AERO

    function setUp() public override {
        super.setUp();

        // Deploy MockOdosRouter for swaps
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        // Create a separate wallet factory
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Deploy wallet factory via PortfolioManager
        (_walletFactory, _walletFacetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("wallet-factory"))));

        // Deploy a separate SwapConfig for wallet (behind proxy)
        SwapConfig swapConfigImpl = new SwapConfig();
        ERC1967Proxy swapConfigProxy = new ERC1967Proxy(address(swapConfigImpl), "");
        _walletSwapConfig = SwapConfig(address(swapConfigProxy));
        _walletSwapConfig.initialize(FORTY_ACRES_DEPLOYER);
        _walletSwapConfig.setApprovedSwapTarget(address(mockRouter), true);

        // Also approve on main swapConfig
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);

        // Deploy WalletFacet to wallet factory
        WalletFacet newWalletFacet = new WalletFacet(
            address(_walletFactory),
            address(_portfolioAccountConfig), // Use main portfolio config for now
            address(_walletSwapConfig)
        );

        // Register WalletFacet selectors
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = WalletFacet.transferERC20.selector;
        selectors[1] = WalletFacet.transferNFT.selector;
        selectors[2] = WalletFacet.swap.selector;
        selectors[3] = WalletFacet.enforceCollateralRequirements.selector;
        _walletFacetRegistry.registerFacet(address(newWalletFacet), selectors, "WalletFacet");

        vm.stopPrank();

        // Create wallet portfolio for the user
        _walletPortfolio = _walletFactory.createAccount(_user);

        // Get WalletFacet reference via wallet portfolio
        walletFacet = WalletFacet(_walletPortfolio);

        // Set up tokens
        inputToken = address(_usdc);
        outputToken = address(_aero);
    }

    // Helper function to add collateral via PortfolioManager multicall (on main portfolio)
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

    // Helper function to borrow to wallet portfolio via PortfolioManager multicall
    function borrowToWalletViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseLendingFacet.borrowTo.selector,
            _walletPortfolio,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper to swap via WalletFacet multicall (on wallet factory)
    function swapViaMulticall(
        address swapTarget,
        bytes memory swapData,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut
    ) internal returns (uint256) {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_walletFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            WalletFacet.swap.selector,
            swapTarget,
            swapData,
            tokenIn,
            amountIn,
            tokenOut,
            minAmountOut
        );
        bytes[] memory results = _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        return abi.decode(results[0], (uint256));
    }

    // Helper to remove collateral to target factory's portfolio via PortfolioManager multicall (on main portfolio)
    function removeCollateralToViaMulticall(uint256 tokenId, address targetFactory) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseCollateralFacet.removeCollateralTo.selector,
            tokenId,
            targetFactory
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper to transfer NFT via WalletFacet multicall (on wallet factory)
    function transferNFTViaMulticall(address nft, uint256 tokenId, address to) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_walletFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            WalletFacet.transferNFT.selector,
            nft,
            tokenId,
            to
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }
    /**
     * @dev Test that WalletFacet.swap works independently
     */
    function testWalletSwap() public {
        uint256 usdcAmount = 100e6;
        uint256 aeroAmount = 50e18;

        // Fund the wallet with USDC
        deal(inputToken, _walletPortfolio, usdcAmount);

        // Approve mock router
        vm.prank(_walletPortfolio);
        IERC20(inputToken).approve(address(mockRouter), usdcAmount);

        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            inputToken,
            outputToken,
            usdcAmount,
            aeroAmount,
            _walletPortfolio
        );

        uint256 swappedAmount = swapViaMulticall(
            address(mockRouter),
            swapData,
            inputToken,
            usdcAmount,
            outputToken,
            aeroAmount
        );

        assertEq(swappedAmount, aeroAmount, "Should swap successfully");
        assertEq(IERC20(outputToken).balanceOf(_walletPortfolio), aeroAmount, "Wallet should have AERO");
    }

    /**
     * @dev Test withdrawing collateral to wallet and re-adding it back to main portfolio
     */
    function testWithdrawCollateralToWalletAndReadd() public {
        // Step 1: Add collateral to main portfolio
        addCollateralViaMulticall(_tokenId);

        // Verify collateral is in main portfolio
        uint256 initialCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(initialCollateral, 0, "Should have initial collateral");
        assertEq(_ve.ownerOf(_tokenId), _portfolioAccount, "Main portfolio should own veNFT");

        console.log("=== Initial State ===");
        console.log("Main portfolio collateral:", initialCollateral);
        console.log("veNFT owner:", _ve.ownerOf(_tokenId));

        // Step 2: Remove collateral to wallet using removeCollateralTo (pass wallet factory)
        removeCollateralToViaMulticall(_tokenId, address(_walletFactory));

        // Verify veNFT is now in wallet
        assertEq(_ve.ownerOf(_tokenId), _walletPortfolio, "Wallet should now own veNFT");

        // Verify collateral is removed from main portfolio tracking
        uint256 afterRemoveCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(afterRemoveCollateral, 0, "Collateral should be zero after removal");

        console.log("=== After Remove to Wallet ===");
        console.log("Main portfolio collateral:", afterRemoveCollateral);
        console.log("veNFT owner:", _ve.ownerOf(_tokenId));

        // Step 3: Transfer NFT from wallet back to main portfolio
        transferNFTViaMulticall(address(_ve), _tokenId, _portfolioAccount);

        // Verify veNFT is back in main portfolio
        assertEq(_ve.ownerOf(_tokenId), _portfolioAccount, "Main portfolio should own veNFT again");

        console.log("=== After Transfer Back ===");
        console.log("veNFT owner:", _ve.ownerOf(_tokenId));

        // Step 4: Re-add collateral to main portfolio
        addCollateralViaMulticall(_tokenId);

        // Verify collateral is tracked again
        uint256 finalCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(finalCollateral, initialCollateral, "Collateral should be restored");

        console.log("=== Final State ===");
        console.log("Main portfolio collateral:", finalCollateral);
        console.log("veNFT owner:", _ve.ownerOf(_tokenId));
    }

    /**
     * @dev Test that removeCollateralTo fails when target factory is not registered
     */
    function testRemoveCollateralToFailsWithUnregisteredFactory() public {
        // Add collateral first
        addCollateralViaMulticall(_tokenId);

        // Try to remove to an unregistered factory address
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseCollateralFacet.removeCollateralTo.selector,
            _tokenId,
            address(0x1234) // Not a registered factory
        );

        vm.expectRevert("Target factory not registered");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }
}
