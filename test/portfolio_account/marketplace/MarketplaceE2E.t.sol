// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {IOpenXSwap} from "../../../src/interfaces/external/IOpenXSwap.sol";

/**
 * @title MarketplaceE2ETest
 * @dev End-to-end test: User has NFT in aerodrome → borrows to wallet → buys NFT from wallet → deposits into aerodrome
 */
contract MarketplaceE2ETest is Test, Setup {
    PortfolioMarketplace public portfolioMarketplace;
    PortfolioFactory public _walletFactory;
    FacetRegistry public _walletFacetRegistry;

    address public seller;
    address public sellerPortfolio;
    address public buyerWallet;

    uint256 public constant LISTING_PRICE = 500e6; // 500 USDC
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%

    // Second NFT for the seller to list
    uint256 public sellerTokenId = 84298;

    function setUp() public override {
        super.setUp();

        seller = address(0xBEEF);

        // Fund vault for borrowing
        deal(address(_usdc), _vault, 1000000e6);

        // Add _user's collateral
        _addCollateral(_user, _tokenId);

        // Set up marketplace
        portfolioMarketplace = PortfolioMarketplace(address(MarketplaceFacet(address(_portfolioAccount)).marketplace()));
        address marketplaceOwner = portfolioMarketplace.owner();
        vm.startPrank(marketplaceOwner);
        portfolioMarketplace.setProtocolFee(PROTOCOL_FEE_BPS);
        portfolioMarketplace.setFeeRecipient(address(0x5678));
        portfolioMarketplace.setAllowedPaymentToken(address(_usdc), true);
        vm.stopPrank();

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

        // Register FortyAcresMarketplaceFacet on wallet factory
        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(_walletFactory),
            address(_portfolioAccountConfig),
            address(_ve),
            address(portfolioMarketplace)
        );
        bytes4[] memory fortyAcresSelectors = new bytes4[](1);
        fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        _walletFacetRegistry.registerFacet(address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");

        vm.stopPrank();

        // Create wallet portfolio for _user
        buyerWallet = _walletFactory.createAccount(_user);

        // Set up seller: create aerodrome portfolio, transfer NFT, add as collateral
        sellerPortfolio = _portfolioFactory.createAccount(seller);

        // Transfer seller's NFT to their portfolio
        address tokenOwner = IVotingEscrow(_ve).ownerOf(sellerTokenId);
        vm.startPrank(tokenOwner);
        IVotingEscrow(_ve).transferFrom(tokenOwner, sellerPortfolio, sellerTokenId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        _addCollateral(seller, sellerTokenId);
    }

    function _addCollateral(address user, uint256 tokenId) internal {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId);
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    /**
     * @dev End-to-end test: Full marketplace purchase flow
     *
     * Flow:
     * 1. User (_user) has NFT #84297 deposited as collateral in aerodrome factory
     * 2. Seller lists NFT #84298 for sale
     * 3. User borrows USDC to their wallet portfolio (accounting for origination fee)
     * 4. User buys seller's listing from their wallet
     * 5. User transfers the purchased NFT from wallet to aerodrome portfolio
     * 6. User deposits the NFT as collateral in aerodrome
     */
    function testEndToEndBorrowAndBuyFromWallet() public {
        // Step 1: Verify initial state
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount, "User should have NFT in aerodrome portfolio");
        assertGt(CollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId), 0, "User should have collateral locked");

        // Step 2: Seller creates a listing
        vm.startPrank(seller);
        {
            address[] memory factories = new address[](1);
            factories[0] = address(_portfolioFactory);
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(
                BaseMarketplaceFacet.makeListing.selector,
                sellerTokenId,
                LISTING_PRICE,
                address(_usdc),
                0, // never expires
                address(0) // no buyer restriction
            );
            _portfolioManager.multicall(data, factories);
        }
        vm.stopPrank();

        // Verify listing was created
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(sellerTokenId);
        assertEq(listing.price, LISTING_PRICE, "Listing should be created");
        uint256 nonce = listing.nonce;

        // Step 3+4: User borrows to wallet and buys listing in single multicall
        // Borrow extra to account for origination fee (fee is deducted from borrowed amount)
        uint256 borrowAmount = (LISTING_PRICE * 10000) / 9920 + 1; // 0.8% origination fee buffer

        vm.startPrank(_user);
        {
            address[] memory factories = new address[](2);
            factories[0] = address(_portfolioFactory); // borrow from aerodrome
            factories[1] = address(_walletFactory);    // buy from wallet

            bytes[] memory data = new bytes[](2);
            data[0] = abi.encodeWithSelector(
                BaseLendingFacet.borrowTo.selector,
                buyerWallet,    // send borrowed USDC to wallet portfolio
                borrowAmount    // borrow enough to cover listing price after fee
            );
            data[1] = abi.encodeWithSelector(
                FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
                sellerTokenId,
                nonce
            );
            _portfolioManager.multicall(data, factories);
        }
        vm.stopPrank();

        // Verify: NFT is now in the buyer's wallet portfolio
        assertEq(IVotingEscrow(_ve).ownerOf(sellerTokenId), buyerWallet, "NFT should be in buyer's wallet");

        // Verify: Aerodrome portfolio has debt (from the borrow)
        uint256 userDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(userDebt, 0, "User should have debt after borrowing");

        // Step 5+6: Transfer NFT from wallet to aerodrome portfolio and add as collateral
        vm.startPrank(_user);
        {
            address[] memory factories = new address[](2);
            factories[0] = address(_walletFactory);    // transfer from wallet
            factories[1] = address(_portfolioFactory); // add collateral to aerodrome

            bytes[] memory data = new bytes[](2);
            data[0] = abi.encodeWithSelector(
                WalletFacet.transferNFT.selector,
                address(_ve),         // NFT contract
                sellerTokenId,        // token ID
                _portfolioAccount     // destination: aerodrome portfolio
            );
            data[1] = abi.encodeWithSelector(
                BaseCollateralFacet.addCollateral.selector,
                sellerTokenId
            );
            _portfolioManager.multicall(data, factories);
        }
        vm.stopPrank();

        // Verify final state:
        // 1. NFT is now in the aerodrome portfolio
        assertEq(IVotingEscrow(_ve).ownerOf(sellerTokenId), _portfolioAccount, "NFT should be in aerodrome portfolio");

        // 2. NFT is locked as collateral
        assertGt(CollateralFacet(_portfolioAccount).getLockedCollateral(sellerTokenId), 0, "NFT should be locked as collateral");

        // 3. User now has 2 NFTs as collateral
        uint256 collateral1 = CollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId);
        uint256 collateral2 = CollateralFacet(_portfolioAccount).getLockedCollateral(sellerTokenId);
        assertGt(collateral1, 0, "Original NFT should still be collateral");
        assertGt(collateral2, 0, "Purchased NFT should be collateral");

        // 4. User still has debt, but now has more collateral to cover it
        uint256 finalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(finalDebt, 0, "User should still have debt");
        (uint256 maxLoan,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        // MaxLoan is remaining borrowing capacity, so maxLoan >= 0 means we're solvent
        // The collateral requirements are enforced by the multicall, so if we got here, we're good
    }

    /**
     * @dev End-to-end test: Single multicall for the entire flow
     * Borrow → Buy → Transfer → Deposit all in one transaction
     */
    function testEndToEndSingleMulticall() public {
        // Seller creates listing first
        vm.startPrank(seller);
        {
            address[] memory factories = new address[](1);
            factories[0] = address(_portfolioFactory);
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(
                BaseMarketplaceFacet.makeListing.selector,
                sellerTokenId,
                LISTING_PRICE,
                address(_usdc),
                0, address(0)
            );
            _portfolioManager.multicall(data, factories);
        }
        vm.stopPrank();

        uint256 nonce = portfolioMarketplace.getListing(sellerTokenId).nonce;

        // User does everything in a single multicall:
        // 1. Borrow to wallet (aerodrome factory) - extra to cover origination fee
        // 2. Buy listing (wallet factory)
        // 3. Transfer NFT to aerodrome (wallet factory)
        // 4. Add as collateral (aerodrome factory)
        uint256 borrowAmount = (LISTING_PRICE * 10000) / 9920 + 1;
        vm.startPrank(_user);
        {
            address[] memory factories = new address[](4);
            factories[0] = address(_portfolioFactory); // borrow
            factories[1] = address(_walletFactory);    // buy
            factories[2] = address(_walletFactory);    // transfer NFT
            factories[3] = address(_portfolioFactory); // add collateral

            bytes[] memory data = new bytes[](4);
            data[0] = abi.encodeWithSelector(
                BaseLendingFacet.borrowTo.selector,
                buyerWallet,
                borrowAmount
            );
            data[1] = abi.encodeWithSelector(
                FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
                sellerTokenId,
                nonce
            );
            data[2] = abi.encodeWithSelector(
                WalletFacet.transferNFT.selector,
                address(_ve),
                sellerTokenId,
                _portfolioAccount
            );
            data[3] = abi.encodeWithSelector(
                BaseCollateralFacet.addCollateral.selector,
                sellerTokenId
            );
            _portfolioManager.multicall(data, factories);
        }
        vm.stopPrank();

        // Verify all outcomes
        assertEq(IVotingEscrow(_ve).ownerOf(sellerTokenId), _portfolioAccount, "NFT should be in aerodrome portfolio");
        assertGt(CollateralFacet(_portfolioAccount).getLockedCollateral(sellerTokenId), 0, "NFT should be locked as collateral");
        assertGt(CollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId), 0, "Original NFT should still be collateral");
        assertGt(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "User should have debt");
    }

    /**
     * @dev End-to-end test: Buy from OpenX marketplace via wallet, then deposit as collateral.
     *      The OpenX listing currency is AERO (not USDC), so we use receiveERC20 to pull
     *      funds from the user's EOA into the wallet before purchasing.
     */
    function testEndToEndBuyFromOpenXViaWallet() public {
        // Register OpenXFacet on wallet factory
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        OpenXFacet openXFacet = new OpenXFacet(
            address(_walletFactory),
            address(_portfolioAccountConfig),
            address(_ve)
        );
        bytes4[] memory openXSelectors = new bytes4[](1);
        openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        _walletFacetRegistry.registerFacet(address(openXFacet), openXSelectors, "OpenXFacet");
        vm.stopPrank();

        // Get OpenX listing details
        uint256 OPENX_LISTING_ID = 10138;
        address OPENX = 0xbDdCf6AB290E7Ad076CA103183730d1Bf0661112;
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

        assertEq(sold, 0, "Listing should not be sold");
        assertEq(nftId, 71305, "Listing tokenId should be 71305");

        // Fund user EOA with listing currency and approve wallet portfolio
        deal(currency, _user, price);
        vm.startPrank(_user);
        IERC20(currency).approve(buyerWallet, price);

        // receiveERC20 → buy from OpenX → transfer NFT → deposit as collateral
        {
            address[] memory factories = new address[](4);
            factories[0] = address(_walletFactory);    // pull funds from EOA
            factories[1] = address(_walletFactory);    // buy from OpenX
            factories[2] = address(_walletFactory);    // transfer NFT
            factories[3] = address(_portfolioFactory); // add collateral

            bytes[] memory data = new bytes[](4);
            data[0] = abi.encodeWithSelector(
                WalletFacet.receiveERC20.selector,
                currency,
                price
            );
            data[1] = abi.encodeWithSelector(
                OpenXFacet.buyOpenXListing.selector,
                OPENX_LISTING_ID
            );
            data[2] = abi.encodeWithSelector(
                WalletFacet.transferNFT.selector,
                veNft,
                nftId,
                _portfolioAccount
            );
            data[3] = abi.encodeWithSelector(
                BaseCollateralFacet.addCollateral.selector,
                nftId
            );
            _portfolioManager.multicall(data, factories);
        }
        vm.stopPrank();

        // Verify NFT is now collateral in aerodrome
        assertEq(IVotingEscrow(veNft).ownerOf(nftId), _portfolioAccount, "NFT should be in aerodrome portfolio");
        assertGt(CollateralFacet(_portfolioAccount).getLockedCollateral(nftId), 0, "NFT should be locked as collateral");
        // Verify user EOA funds were spent
        assertEq(IERC20(currency).balanceOf(_user), 0, "User should have spent all funds");
    }
}
