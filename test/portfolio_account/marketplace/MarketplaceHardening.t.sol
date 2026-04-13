// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {UserMarketplaceModule} from "../../../src/facets/account/marketplace/UserMarketplaceModule.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";

contract MarketplaceHardeningTest is Test, LocalSetup {
    uint256 public constant LISTING_PRICE = 1000e6;
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    uint256 constant BLOCK_START = 100;

    PortfolioMarketplace public portfolioMarketplace;
    PortfolioFactory public _walletFactory;
    FacetRegistry public _walletFacetRegistry;
    address public buyer;
    address public feeRecipient;
    uint256 public _tokenId3;

    function setUp() public override {
        super.setUp();

        buyer = address(0x1234);
        feeRecipient = address(0x5678);

        addCollateralViaMulticall(_tokenId);
        deal(address(_usdc), _vault, 100_000e6);

        portfolioMarketplace = PortfolioMarketplace(
            address(MarketplaceFacet(address(_portfolioAccount)).marketplace())
        );

        address marketplaceOwner = portfolioMarketplace.owner();
        vm.startPrank(marketplaceOwner);
        portfolioMarketplace.setProtocolFee(PROTOCOL_FEE_BPS);
        portfolioMarketplace.setFeeRecipient(feeRecipient);
        portfolioMarketplace.setAllowedPaymentToken(address(_usdc), true);
        vm.stopPrank();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (_walletFactory, _walletFacetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("wallet")))
        );

        WalletFacet walletFacet = new WalletFacet(
            address(_walletFactory),
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

        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(_walletFactory),
            address(_ve),
            address(portfolioMarketplace)
        );
        bytes4[] memory fortyAcresSelectors = new bytes4[](1);
        fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        _walletFacetRegistry.registerFacet(address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");
        vm.stopPrank();

        vm.startPrank(buyer);
        _walletFactory.createAccount(buyer);
        vm.stopPrank();

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE * 10);

        _tokenId3 = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
    }

    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function makeListingViaMulticall(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer
    ) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            tokenId, price, paymentToken, expiresAt, allowedBuyer
        );
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function purchaseListingViaMulticall(
        address buyerEoa,
        uint256 tokenId,
        uint256 price
    ) internal {
        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;
        address buyerWallet = _walletFactory.portfolioOf(buyerEoa);
        if (IERC20(_usdc).balanceOf(buyerWallet) < price) {
            deal(address(_usdc), buyerWallet, price);
        }
        vm.startPrank(buyerEoa);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            tokenId, nonce
        );
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _computeMaxLoanIgnoreSupply(uint256 collateral) internal view returns (uint256) {
        uint256 rewardsRate = _loanConfig.getRewardsRate();
        uint256 multiplier = _loanConfig.getMultiplier();
        return (((collateral * rewardsRate) / 1_000_000) * multiplier) / 1e12;
    }

    // --- Sale does not leave seller over-borrowed ---

    function test_salePaysSufficientDebt_sellerStaysHealthy() public {
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(_tokenId2);

        uint256 collateral2 = CollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId2);
        uint256 maxLoanToken2Only = _computeMaxLoanIgnoreSupply(collateral2);

        uint256 borrowAmount = maxLoanToken2Only + 100e6;
        (, uint256 maxLoanBoth) = CollateralFacet(_portfolioAccount).getMaxLoan();
        deal(address(_usdc), _vault, (maxLoanBoth * 10000) / 8000);
        (uint256 maxAvail, ) = CollateralFacet(_portfolioAccount).getMaxLoan();
        if (borrowAmount > maxAvail) {
            borrowAmount = maxAvail;
        }

        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, maxLoanToken2Only);

        uint256 requiredPayment = totalDebt - maxLoanToken2Only;
        uint256 listingPrice = (requiredPayment * 10000) / (10000 - PROTOCOL_FEE_BPS) + 1e6;

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, listingPrice, address(_usdc), 0, address(0));

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, listingPrice);

        vm.roll(BLOCK_START + 3);
        purchaseListingViaMulticall(buyer, _tokenId, listingPrice);

        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        (, uint256 maxLoanAfter) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertLe(debtAfter, maxLoanAfter);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet);
    }

    function test_salePriceInsufficientForDebt_reverts() public {
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(400e6);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 lowPrice = totalDebt / 2;

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId, lowPrice, address(_usdc), uint256(0), address(0)
        );
        vm.expectRevert("Price too low to cover debt after fees");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));
    }

    function test_saleWithZeroDebt_allProceedsToSeller() public {
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);

        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);
        uint256 feeRecipientBefore = IERC20(_usdc).balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);

        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        assertEq(IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore, LISTING_PRICE - expectedFee);
        assertEq(IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBefore, expectedFee);
    }

    function test_saleOfOnlyToken_mustPayAllDebt() public {
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(300e6);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 minPrice = (totalDebt * 10000) / (10000 - PROTOCOL_FEE_BPS) + 1;
        uint256 listingPrice = minPrice + 100e6;

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, listingPrice, address(_usdc), 0, address(0));

        deal(address(_usdc), _walletFactory.portfolioOf(buyer), listingPrice);

        vm.roll(BLOCK_START + 3);
        purchaseListingViaMulticall(buyer, _tokenId, listingPrice);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _walletFactory.portfolioOf(buyer));
    }

    function test_saleOfOnlyToken_priceCannotCoverDebt_reverts() public {
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(500e6);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 insufficientPrice = (totalDebt * (10000 - PROTOCOL_FEE_BPS)) / 10000 - 1;
        if (insufficientPrice < 10000) insufficientPrice = 10000;

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId, insufficientPrice, address(_usdc), uint256(0), address(0)
        );
        vm.expectRevert("Price too low to cover debt after fees");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // --- Buyer cannot be over-borrowed by purchase ---

    function test_buyerReceivesNFT() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        uint256 buyerUsdcBefore = IERC20(_usdc).balanceOf(buyerWallet);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet);
        assertEq(buyerUsdcBefore - IERC20(_usdc).balanceOf(buyerWallet), LISTING_PRICE);
    }

    function test_buyerWithExistingDebt_purchaseDoesNotAffectDebt() public {
        address debtBuyer = address(0xDB01);
        uint256 debtBuyerTokenId = _mockVe.mintTo(address(this), int128(uint128(3000e18)));
        address debtBuyerPortfolio = _portfolioFactory.createAccount(debtBuyer);

        _mockVe.transferFrom(address(this), debtBuyerPortfolio, debtBuyerTokenId);

        vm.startPrank(debtBuyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, debtBuyerTokenId);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        vm.roll(BLOCK_START + 1);
        vm.startPrank(debtBuyer);
        cd[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, uint256(100e6));
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        uint256 debtBefore = CollateralFacet(debtBuyerPortfolio).getTotalDebt();
        assertGt(debtBefore, 0);

        vm.prank(debtBuyer);
        _walletFactory.createAccount(debtBuyer);
        address debtBuyerWallet = _walletFactory.portfolioOf(debtBuyer);
        deal(address(_usdc), debtBuyerWallet, LISTING_PRICE);

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.roll(BLOCK_START + 3);
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;
        vm.startPrank(debtBuyer);
        pf[0] = address(_walletFactory);
        cd[0] = abi.encodeWithSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector, _tokenId, nonce);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        assertEq(CollateralFacet(debtBuyerPortfolio).getTotalDebt(), debtBefore);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), debtBuyerWallet);
    }

    // --- Marketplace cannot circumvent borrow limits ---

    function test_borrowToCapacity_thenSell_fullyUnwinds() public {
        (uint256 maxAvail, ) = CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 borrowAmount = maxAvail > 10e6 ? maxAvail - 10e6 : maxAvail;

        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 minPrice = (totalDebt * 10000) / (10000 - PROTOCOL_FEE_BPS) + 1;
        uint256 listingPrice = minPrice + 50e6;

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, listingPrice, address(_usdc), 0, address(0));

        deal(address(_usdc), _walletFactory.portfolioOf(buyer), listingPrice);

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);

        vm.roll(BLOCK_START + 3);
        purchaseListingViaMulticall(buyer, _tokenId, listingPrice);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);

        uint256 expectedFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        uint256 netPayment = listingPrice - expectedFee;
        assertEq(IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore, netPayment - totalDebt);
    }

    function test_selfTrade_doesNotCreateBadDebt() public {
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(200e6);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 netPayment = LISTING_PRICE - (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        assertGt(netPayment, totalDebt);

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.prank(_user);
        _walletFactory.createAccount(_user);
        address userWallet = _walletFactory.portfolioOf(_user);
        deal(address(_usdc), userWallet, LISTING_PRICE);

        uint256 feeRecipientBefore = IERC20(_usdc).balanceOf(feeRecipient);

        vm.roll(BLOCK_START + 3);
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector, _tokenId, nonce);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), userWallet);

        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        assertEq(IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBefore, expectedFee);
    }

    function test_underwaterSeller_canSellIfPriceCoversDebt() public {
        (uint256 maxAvail, ) = CollateralFacet(_portfolioAccount).getMaxLoan();
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(maxAvail);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setRewardsRate(5000);
        vm.stopPrank();

        (, uint256 maxLoanAfter) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertGt(totalDebt, maxLoanAfter);

        uint256 listingPrice = (totalDebt * 10000) / (10000 - PROTOCOL_FEE_BPS) + 100e6;

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, listingPrice, address(_usdc), 0, address(0));

        deal(address(_usdc), _walletFactory.portfolioOf(buyer), listingPrice);

        vm.roll(BLOCK_START + 3);
        purchaseListingViaMulticall(buyer, _tokenId, listingPrice);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
    }

    function test_underwaterSeller_cannotSellIfPriceTooLow() public {
        (uint256 maxAvail, ) = CollateralFacet(_portfolioAccount).getMaxLoan();
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(maxAvail);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setRewardsRate(5000);
        vm.stopPrank();

        uint256 lowPrice = totalDebt / 2;
        if (lowPrice < 10000) lowPrice = 10000;

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId, lowPrice, address(_usdc), uint256(0), address(0)
        );
        vm.expectRevert("Price too low to cover debt after fees");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // --- Fee change edge case ---

    function test_protocolFeeIncrease_preventsUnderfundedSale() public {
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(400e6);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 tightPrice = (totalDebt * 10000) / (10000 - PROTOCOL_FEE_BPS) + 1;

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, tightPrice, address(_usdc), 0, address(0));

        vm.prank(portfolioMarketplace.owner());
        portfolioMarketplace.setProtocolFee(1000);

        uint256 newNet = tightPrice - (tightPrice * 1000) / 10000;
        assertLt(newNet, totalDebt);

        (bool purchasable, , ) = IMarketplaceFacet(_portfolioAccount).isListingPurchasable(_tokenId);
        assertFalse(purchasable);

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, tightPrice);
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;

        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector, _tokenId, nonce);
        vm.expectRevert("Debt exceeds max loan");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function test_requiredPaymentCalculation() public {
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(_tokenId2);

        uint256 collateral2 = CollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId2);
        uint256 newMaxLoanAfterRemoval = _computeMaxLoanIgnoreSupply(collateral2);

        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(100e6);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 expectedRequiredPayment = totalDebt > newMaxLoanAfterRemoval
            ? totalDebt - newMaxLoanAfterRemoval
            : 0;

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        (, uint256 requiredPayment, uint256 netPayment) =
            IMarketplaceFacet(_portfolioAccount).isListingPurchasable(_tokenId);

        assertEq(requiredPayment, expectedRequiredPayment);

        uint256 expectedNet = LISTING_PRICE - (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        assertEq(netPayment, expectedNet);
    }

    function test_listingBecomesUnpurchasable_afterDebtIncrease() public {
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(_tokenId2);

        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(50e6);

        uint256 smallPrice = 100e6;
        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, smallPrice, address(_usdc), 0, address(0));

        (bool purchasableBefore, , ) = IMarketplaceFacet(_portfolioAccount).isListingPurchasable(_tokenId);
        assertTrue(purchasableBefore);

        uint256 collateral2 = CollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId2);
        uint256 maxLoanToken2Only = _computeMaxLoanIgnoreSupply(collateral2);
        uint256 netOfSmallPrice = smallPrice - (smallPrice * PROTOCOL_FEE_BPS) / 10000;
        (uint256 maxAvail, ) = CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 targetBorrow = maxLoanToken2Only + netOfSmallPrice + 1e6;
        uint256 currentDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 additionalBorrow = targetBorrow > currentDebt ? targetBorrow - currentDebt : 0;
        if (additionalBorrow > maxAvail) {
            additionalBorrow = maxAvail;
        }

        if (additionalBorrow > 0) {
            deal(address(_usdc), _vault, 500_000e6);
            vm.roll(BLOCK_START + 3);
            borrowViaMulticall(additionalBorrow);
        }

        (bool purchasableAfter, uint256 reqPay, uint256 netPay) =
            IMarketplaceFacet(_portfolioAccount).isListingPurchasable(_tokenId);
        assertFalse(purchasableAfter);
        assertGt(reqPay, netPay);

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, smallPrice);
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;

        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector, _tokenId, nonce);
        vm.expectRevert("Debt exceeds max loan");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    // --- Events ---

    function test_saleEmitsSaleProceededEvent() public {
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(200e6);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedNetPayment = LISTING_PRICE - expectedFee;

        vm.roll(BLOCK_START + 2);
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        deal(address(_usdc), _walletFactory.portfolioOf(buyer), LISTING_PRICE);

        vm.expectEmit(true, true, false, true, _portfolioAccount);
        emit BaseMarketplaceFacet.SaleProceeded(_tokenId, _walletFactory.portfolioOf(buyer), expectedNetPayment, totalDebt);

        vm.roll(BLOCK_START + 3);
        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);
    }

    function test_purchaseEmitsListingPurchasedEvent() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;

        vm.expectEmit(true, true, true, true, address(portfolioMarketplace));
        emit PortfolioMarketplace.ListingPurchased(
            _tokenId, _walletFactory.portfolioOf(buyer), _portfolioAccount, LISTING_PRICE, expectedFee
        );

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);
    }

    function test_saleWithZeroDebt_emitsZeroDebtPaid() public {
        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;

        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.expectEmit(true, true, false, true, _portfolioAccount);
        emit BaseMarketplaceFacet.SaleProceeded(
            _tokenId, _walletFactory.portfolioOf(buyer), LISTING_PRICE - expectedFee, 0
        );

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);
    }

    // --- Access control ---

    function test_receiveSaleProceeds_onlyCallableByMarketplace() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));
        address buyerWallet = _walletFactory.portfolioOf(buyer);

        vm.prank(address(0xBAD));
        vm.expectRevert("Not marketplace");
        IMarketplaceFacet(_portfolioAccount).receiveSaleProceeds(_tokenId, buyerWallet, LISTING_PRICE);

        vm.prank(_user);
        vm.expectRevert("Not marketplace");
        IMarketplaceFacet(_portfolioAccount).receiveSaleProceeds(_tokenId, buyerWallet, LISTING_PRICE);
    }

    function test_clearExpiredSaleAuthorization_onlyCallableByMarketplace() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));
        assertTrue(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));

        vm.prank(address(0xBAD));
        vm.expectRevert("Not marketplace");
        IMarketplaceFacet(_portfolioAccount).clearExpiredSaleAuthorization(_tokenId);

        assertTrue(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));
    }

    function test_makeListing_onlyCallableViaMulticall() public {
        vm.prank(_user);
        vm.expectRevert();
        BaseMarketplaceFacet(_portfolioAccount).makeListing(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));
    }

    function test_cancelListing_onlyCallableViaMulticall() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.prank(_user);
        vm.expectRevert();
        BaseMarketplaceFacet(_portfolioAccount).cancelListing(_tokenId);
    }

    function test_createListing_onlyCallableByRegisteredPortfolio() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(PortfolioMarketplace.InvalidPortfolio.selector));
        portfolioMarketplace.createListing(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));
    }

    function test_cancelListing_onlyByListingOwner() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.prank(address(0xBAD));
        vm.expectRevert("Not listing owner");
        portfolioMarketplace.cancelListing(_tokenId);
    }

    // --- Listing parameters ---

    function test_makeListing_atMinimumPrice() public {
        makeListingViaMulticall(_tokenId, 10000, address(_usdc), 0, address(0));
        assertTrue(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));
    }

    function test_makeListing_belowMinimumPrice_reverts() public {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId, uint256(9999), address(_usdc), uint256(0), address(0)
        );
        vm.expectRevert("Price below minimum");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function test_makeListing_wrongPaymentToken_withDebt_reverts() public {
        MockERC20 altToken = new MockERC20("Alt Token", "ALT", 6);
        vm.prank(portfolioMarketplace.owner());
        portfolioMarketplace.setAllowedPaymentToken(address(altToken), true);

        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(100e6);

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId, LISTING_PRICE, address(altToken), uint256(0), address(0)
        );
        vm.expectRevert("Payment token must match debt token");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function test_makeListing_wrongPaymentToken_noDebt_succeeds() public {
        MockERC20 altToken = new MockERC20("Alt Token", "ALT", 6);
        vm.prank(portfolioMarketplace.owner());
        portfolioMarketplace.setAllowedPaymentToken(address(altToken), true);

        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(altToken), 0, address(0));
        assertTrue(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));
    }

    function test_makeListing_duplicate_reverts() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId, LISTING_PRICE + 100e6, address(_usdc), uint256(0), address(0)
        );
        vm.expectRevert("Listing already exists");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function test_makeListing_tokenNotLocked_reverts() public {
        _mockVe.transferFrom(address(this), _portfolioAccount, _tokenId3);

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId3, LISTING_PRICE, address(_usdc), uint256(0), address(0)
        );
        vm.expectRevert("Token not locked");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function test_createListing_disallowedPaymentToken_reverts() public {
        MockERC20 notAllowed = new MockERC20("Bad Token", "BAD", 18);

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId, LISTING_PRICE, address(notAllowed), uint256(0), address(0)
        );
        vm.expectRevert("Payment token not allowed");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // --- Nonce / frontrunning ---

    function test_purchaseWithWrongNonce_reverts() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 wrongNonce = portfolioMarketplace.getListing(_tokenId).nonce + 1;
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE);

        vm.startPrank(buyerWallet);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert("Nonce mismatch");
        portfolioMarketplace.purchaseListing(_tokenId, wrongNonce);
        vm.stopPrank();
    }

    // --- Expiration ---

    function test_purchaseExpiredListing_reverts() public {
        uint256 expiresAt = 1700000002 + 3600;
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), expiresAt, address(0));

        vm.warp(expiresAt + 1);
        vm.roll(BLOCK_START + 10);

        (bool purchasable, , ) = IMarketplaceFacet(_portfolioAccount).isListingPurchasable(_tokenId);
        assertFalse(purchasable);

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE);
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;

        vm.startPrank(buyerWallet);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.ListingExpired.selector);
        portfolioMarketplace.purchaseListing(_tokenId, nonce);
        vm.stopPrank();
    }

    function test_cleanExpiredListings_removesAuthAndListing() public {
        uint256 expiresAt = 1700000002 + 3600;
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), expiresAt, address(0));

        assertTrue(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));

        vm.warp(expiresAt + 1);
        vm.roll(BLOCK_START + 10);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;
        portfolioMarketplace.cleanExpiredListings(tokenIds);

        assertEq(portfolioMarketplace.getListing(_tokenId).owner, address(0));
        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));
    }

    // --- Cancel listing ---

    function test_cancelListing_removesAuthAndListing() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, _tokenId);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId));
        assertEq(portfolioMarketplace.getListing(_tokenId).owner, address(0));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function test_cancelThenRelist_succeeds() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, _tokenId);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        uint256 newPrice = 2000e6;
        makeListingViaMulticall(_tokenId, newPrice, address(_usdc), 0, address(0));

        (uint256 authPrice, ) = IMarketplaceFacet(_portfolioAccount).getSaleAuthorization(_tokenId);
        assertEq(authPrice, newPrice);
    }

    // --- Allowed buyer ---

    function test_allowedBuyer_wrongBuyer_reverts() public {
        address buyer2 = address(0xBEEF99);
        vm.prank(buyer2);
        _walletFactory.createAccount(buyer2);

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, buyerWallet);

        address buyer2Wallet = _walletFactory.portfolioOf(buyer2);
        deal(address(_usdc), buyer2Wallet, LISTING_PRICE);
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;

        vm.startPrank(buyer2Wallet);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.BuyerNotAllowed.selector);
        portfolioMarketplace.purchaseListing(_tokenId, nonce);
        vm.stopPrank();
    }

    function test_allowedBuyer_correctBuyer_succeeds() public {
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, buyerWallet);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet);
    }

    // --- isListingPurchasable edge cases ---

    function test_isListingPurchasable_nonexistentListing_returnsFalse() public {
        (bool purchasable, uint256 reqPay, uint256 netPay) =
            IMarketplaceFacet(_portfolioAccount).isListingPurchasable(999999);

        assertFalse(purchasable);
        assertEq(reqPay, 0);
        assertEq(netPay, 0);
    }

    function test_isListingPurchasable_wrongPaymentToken_withDebt() public {
        MockERC20 altToken = new MockERC20("Alt Token", "ALT", 6);
        vm.prank(portfolioMarketplace.owner());
        portfolioMarketplace.setAllowedPaymentToken(address(altToken), true);

        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(altToken), 0, address(0));

        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(_tokenId2);

        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(100e6);

        (bool purchasable, uint256 reqPay, ) =
            IMarketplaceFacet(_portfolioAccount).isListingPurchasable(_tokenId);

        if (reqPay > 0) {
            assertFalse(purchasable);
        }
    }

    // --- Admin functions ---

    function test_setProtocolFee_aboveMax_reverts() public {
        vm.prank(portfolioMarketplace.owner());
        vm.expectRevert("Fee too high");
        portfolioMarketplace.setProtocolFee(1001);
    }

    function test_setProtocolFee_atMax_succeeds() public {
        vm.prank(portfolioMarketplace.owner());
        portfolioMarketplace.setProtocolFee(1000);
        assertEq(portfolioMarketplace.protocolFeeBps(), 1000);
    }

    function test_setProtocolFee_nonOwner_reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        portfolioMarketplace.setProtocolFee(100);
    }

    function test_setFeeRecipient_zeroAddress_reverts() public {
        vm.prank(portfolioMarketplace.owner());
        vm.expectRevert("Invalid address");
        portfolioMarketplace.setFeeRecipient(address(0));
    }

    function test_setAllowedPaymentToken_zeroAddress_reverts() public {
        vm.prank(portfolioMarketplace.owner());
        vm.expectRevert("Invalid token");
        portfolioMarketplace.setAllowedPaymentToken(address(0), true);
    }

    // --- Miscellaneous ---

    function test_purchaseNonExistentListing_reverts() public {
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE);

        vm.startPrank(buyerWallet);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.InvalidListing.selector);
        portfolioMarketplace.purchaseListing(999999, 0);
        vm.stopPrank();
    }

    function test_listingEnumeration_reflectsState() public {
        assertEq(portfolioMarketplace.getListingCount(), 0);

        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));
        assertEq(portfolioMarketplace.getListingCount(), 1);

        uint256[] memory ids = portfolioMarketplace.getListingIds(0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], _tokenId);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);
        assertEq(portfolioMarketplace.getListingCount(), 0);
    }

    function test_getListingIds_offsetBeyondCount_returnsEmpty() public {
        uint256[] memory ids = portfolioMarketplace.getListingIds(100, 10);
        assertEq(ids.length, 0);
    }

    function test_recoverTokens_onlyOwner() public {
        deal(address(_usdc), address(portfolioMarketplace), 100e6);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        portfolioMarketplace.recoverTokens(address(_usdc), address(0xBAD), 100e6);

        address mktOwner = portfolioMarketplace.owner();
        uint256 ownerBalBefore = IERC20(_usdc).balanceOf(mktOwner);
        vm.prank(mktOwner);
        portfolioMarketplace.recoverTokens(address(_usdc), mktOwner, 100e6);
        assertEq(IERC20(_usdc).balanceOf(mktOwner) - ownerBalBefore, 100e6);
    }

    function test_recoverTokens_zeroRecipient_reverts() public {
        deal(address(_usdc), address(portfolioMarketplace), 100e6);
        vm.prank(portfolioMarketplace.owner());
        vm.expectRevert("Invalid recipient");
        portfolioMarketplace.recoverTokens(address(_usdc), address(0), 100e6);
    }
}
