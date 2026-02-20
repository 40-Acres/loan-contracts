// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {Setup} from "../portfolio_account/utils/Setup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {IOpenXSwap} from "../../../src/interfaces/external/IOpenXSwap.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";

contract OpenXMarketplaceTest is Test, Setup {
    uint256 constant OPENX_LISTING_ID = 10138; // Listing ID for tokenId 10138
    address constant OPENX = 0xbDdCf6AB290E7Ad076CA103183730d1Bf0661112;
    MockOdosRouterRL public mockRouter;

    PortfolioFactory public _walletFactory;
    FacetRegistry public _walletFacetRegistry;
    address public _walletPortfolio;

    function setUp() public override {
        super.setUp();

        // Deploy wallet factory
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (_walletFactory, _walletFacetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("wallet")))
        );

        // Register WalletFacet on wallet factory
        WalletFacet walletFacet = new WalletFacet(
            address(_walletFactory),
            address(_portfolioAccountConfig),
            address(_swapConfig)
        );
        bytes4[] memory walletSelectors = new bytes4[](6);
        walletSelectors[0] = WalletFacet.transferERC20.selector;
        walletSelectors[1] = WalletFacet.transferNFT.selector;
        walletSelectors[2] = WalletFacet.receiveERC20.selector;
        walletSelectors[3] = WalletFacet.swap.selector;
        walletSelectors[4] = WalletFacet.enforceCollateralRequirements.selector;
        walletSelectors[5] = WalletFacet.onERC721Received.selector;
        _walletFacetRegistry.registerFacet(address(walletFacet), walletSelectors, "WalletFacet");

        // Register OpenXFacet on wallet factory
        OpenXFacet openXFacet = new OpenXFacet(
            address(_walletFactory),
            address(_portfolioAccountConfig),
            address(_ve)
        );
        bytes4[] memory openXSelectors = new bytes4[](1);
        openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        _walletFacetRegistry.registerFacet(address(openXFacet), openXSelectors, "OpenXFacet");

        vm.stopPrank();

        // Create wallet portfolio for user
        _walletPortfolio = _walletFactory.createAccount(_user);
    }

    // Helper function to add collateral via PortfolioManager multicall
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

    // Helper function to borrow via PortfolioManager multicall
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

    function testBuyOpenXListingNoLoan() public {
        // ensure openx listing is still available, and get the price/currency
        (
            address veNft,
            ,
            ,
            uint256 nftId,
            address currency,
            uint256 price,
            ,
            ,
            uint256 sold
        ) = IOpenXSwap(OPENX).Listings(OPENX_LISTING_ID);

        // Verify this is the correct tokenId
        assertEq(nftId, 71305, "Listing tokenId should be 71305");
        assertEq(sold, 0, "Listing should not be sold");

        // Fund wallet portfolio with currency (internal balance)
        deal(currency, _walletPortfolio, price);

        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_walletFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            OpenXFacet.buyOpenXListing.selector,
            OPENX_LISTING_ID
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Assert NFT is now owned by wallet portfolio
        assertEq(IVotingEscrow(veNft).ownerOf(nftId), _walletPortfolio, "Wallet should own the NFT");
    }

    function testBuyOpenXListingWithSwap() public {
        // ensure openx listing is still available, and get the price/currency
        (
            address veNft,
            ,
            ,
            uint256 nftId,
            address currency,
            uint256 price,
            ,
            ,
            uint256 sold
        ) = IOpenXSwap(OPENX).Listings(OPENX_LISTING_ID);

        // Verify this is the correct tokenId
        assertEq(nftId, 71305, "Listing tokenId should be 71305");
        assertEq(sold, 0, "Listing should not be sold");

        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        // Approve the mock router as a swap target (requires owner)
        vm.startPrank(_owner);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();

        // Fund wallet portfolio with USDC (input token for swap)
        deal(address(_usdc), _walletPortfolio, price);

        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](2);
        portfolioFactories[0] = address(_walletFactory);
        portfolioFactories[1] = address(_walletFactory);
        bytes[] memory calldatas = new bytes[](2);

        // Create swap data to call executeSwap on MockOdosRouter
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            _usdc,            // inputToken
            currency,         // outputToken
            price,            // inputAmount
            price,            // amountOut
            _walletPortfolio  // receiver
        );

        calldatas[0] = abi.encodeWithSelector(
            WalletFacet.swap.selector,
            address(mockRouter),  // swapTarget
            swapData,            // swapData
            _usdc,               // inputToken
            price,               // inputAmount
            currency,            // outputToken
            price                // minimumOutputAmount
        );
        calldatas[1] = abi.encodeWithSelector(
            OpenXFacet.buyOpenXListing.selector,
            OPENX_LISTING_ID
        );

        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Assert NFT is now owned by wallet portfolio
        assertEq(IVotingEscrow(veNft).ownerOf(nftId), _walletPortfolio, "Wallet should own the NFT");
    }

}
