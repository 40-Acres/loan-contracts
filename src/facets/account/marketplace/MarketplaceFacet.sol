// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccessControl} from "../utils/AccessControl.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {UserMarketplaceModule} from "./UserMarketplaceModule.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {CollateralFacet} from "../collateral/CollateralFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IMarketplaceFacet} from "../../../interfaces/IMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../marketplace/PortfolioMarketplace.sol";

contract MarketplaceFacet is AccessControl, IMarketplaceFacet {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    address public immutable _marketplace;

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address marketplace) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(votingEscrow != address(0));
        require(marketplace != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _marketplace = marketplace;
    }

    event MarketplaceListingBought(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 debtAttached, address indexed owner);
    
    function marketplace() external view returns (address) {
        return _marketplace;
    }

    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 debtAttached,
        uint256 expiresAt,
        address allowedBuyer
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        CollateralFacet collateralFacet = CollateralFacet(address(this));
        require(collateralFacet.getLockedCollateral(tokenId) > 0, "Token not locked");
        require(collateralFacet.getOriginTimestamp(tokenId) > 0, "Token not originated");
        // if user has debt, require the payment token to be the same as the debt token
        if(debtAttached > 0) {
            require(paymentToken == _portfolioAccountConfig.getDebtToken(), "Payment token must be the same as the debt token");
        }
        UserMarketplaceModule.createListing(tokenId, price, paymentToken, debtAttached, expiresAt, allowedBuyer);
    }

    function cancelListing(uint256 tokenId) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.removeListing(tokenId);
    }

    /**
     * @notice Get listing details for a token
     * @param tokenId The token ID
     * @return listing The listing details
     */
    function getListing(uint256 tokenId) external view returns (UserMarketplaceModule.Listing memory) {
        return UserMarketplaceModule.getListing(tokenId);
    }

    /**
     * @notice Processes payment from marketplace and approves buyer for NFT transfer
     * @dev Called by marketplace after taking funds from buyer. Buyer must be a portfolio account.
     *      Approves buyer to transfer NFT. Buyer must call finalizePurchase to complete the purchase.
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer (must be a portfolio account)
     * @param paymentAmount The amount being paid (should match listing price)
     */
    function processPayment(
        uint256 tokenId,
        address buyer,
        uint256 paymentAmount
    ) external {
        require(msg.sender == _marketplace, "Not marketplace");
        require(buyer != address(0), "Invalid buyer");
        
        // Get listing from user marketplace module
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        
        // Validate listing exists
        require(listing.owner != address(0), "Listing does not exist");
        
        // Ensure listing hasn't expired (0 = never expires)
        require(listing.expiresAt == 0 || listing.expiresAt > block.timestamp, "Listing expired");
        
        // Validate buyer if restricted
        require(listing.allowedBuyer == address(0) || listing.allowedBuyer == buyer, "Buyer not allowed");
        
        // Validate payment amount matches listing price
        require(paymentAmount == listing.price, "Payment amount mismatch");
        
        // Verify token is owned by this portfolio account
        require(_votingEscrow.ownerOf(tokenId) == address(this), "Token not in portfolio");
        
        // Check that token has locked collateral
        require(CollateralFacet(address(this)).getLockedCollateral(tokenId) > 0, "Token not locked");
        
        // Get portfolio owner (seller)
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        
        // Transfer payment token from marketplace to this portfolio account
        IERC20 paymentToken = IERC20(listing.paymentToken);


        // take fees from the payment amount
        PortfolioMarketplace market = PortfolioMarketplace(address(_marketplace));
        uint256 protocolFee = (paymentAmount * market.protocolFee()) / 10000;
        paymentToken.safeTransferFrom(msg.sender, market.feeRecipient(), protocolFee);

        paymentAmount = paymentAmount - protocolFee;
        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        
        
        // Handle payment based on whether debt is attached
        // - If debtAttached == 0: listing price pays down debt, excess goes to seller
        // - If debtAttached > 0: listing price goes directly to seller, debt will be transferred to buyer
        CollateralFacet collateralFacet = CollateralFacet(address(this));
        uint256 totalDebt = collateralFacet.getTotalDebt();
        if(listing.debtAttached == 0) {
            // No debt attached, so handle payment normally
            if(totalDebt > 0) {
                // Pay down debt with payment, transfer excess to seller
                uint256 excess = CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), paymentAmount);
                if(excess > 0) {
                    paymentToken.safeTransfer(portfolioOwner, excess);
                }
            } else {
                // No debt, transfer full payment to seller
                paymentToken.safeTransfer(portfolioOwner, paymentAmount);
            }
        } else {
            // Debt attached - transfer full payment to seller, debt will be transferred separately
            paymentToken.safeTransfer(portfolioOwner, paymentAmount);
        }
        
        // Get buyer's portfolio account (buyer parameter is the EOA, but we need to approve the portfolio account)
        address buyerPortfolio = _portfolioFactory.portfolioOf(buyer);
        require(buyerPortfolio != address(0), "Buyer must have a portfolio account");
        
        // Approve buyer's portfolio account to transfer the NFT
        _votingEscrow.approve(buyerPortfolio, tokenId);
        
        // Remove listing from user marketplace module
        UserMarketplaceModule.removeListing(tokenId);
    }

    /**
     * @notice Finalize purchase by transferring NFT and debt from seller
     * @param seller The seller's portfolio account address
     * @param tokenId The token ID being purchased
     * @param debtAmount The amount of debt to transfer
     * @dev Called by marketplace to complete the purchase. Seller must have approved this account in processPayment.
     *      Calculates proportional unpaid fees based on debt amount.
     */
    function finalizePurchase(
        address seller,
        uint256 tokenId,
        uint256 debtAmount
    ) external {
        require(msg.sender == _marketplace, "Only marketplace can finalize purchase");
        require(_portfolioFactory.isPortfolio(seller), "Seller must be a portfolio account");
        require(seller != address(this), "Cannot purchase from self");
        
        
        // Calculate proportional unpaid fees if there's debt to transfer
        uint256 unpaidFeesToTransfer = 0;
        if (debtAmount > 0) {
            // Get seller's total debt and unpaid fees
            uint256 sellerTotalDebt = CollateralFacet(seller).getTotalDebt();
            uint256 sellerUnpaidFees = CollateralFacet(seller).getUnpaidFees();
            
            // Cap debt amount to seller's actual total debt
            if (debtAmount > sellerTotalDebt) {
                debtAmount = sellerTotalDebt;
            }
            
            // Calculate proportional unpaid fees
            if (sellerUnpaidFees > 0 && sellerTotalDebt > 0) {
                unpaidFeesToTransfer = (sellerUnpaidFees * debtAmount) / sellerTotalDebt;
            }
            
            // Transfer debt away from seller by calling seller's MarketplaceFacet
            // This must happen before NFT transfer since transferDebtToBuyer checks token ownership
            IMarketplaceFacet(seller).transferDebtToBuyer(tokenId, address(this), debtAmount, unpaidFeesToTransfer);
        }
        
        // Transfer NFT from seller to this portfolio account (buyer)
        // Seller must have approved this account in processPayment
        _votingEscrow.transferFrom(seller, address(this), tokenId);
        
        // Add collateral to buyer's account BEFORE adding debt (to avoid undercollateralization)
        CollateralManager.addLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
        
        // Add debt to buyer's account AFTER adding collateral
        if (debtAmount > 0) {
            CollateralManager.addDebt(address(_portfolioAccountConfig), debtAmount, unpaidFeesToTransfer);
        }
    }

    /**
     * @notice Transfer debt away from this portfolio account (seller) to buyer
     * @dev Called by buyer's finalizePurchase to transfer debt
     * @param tokenId The token ID being purchased
     * @param buyer The buyer's portfolio account address
     * @param debtAmount The amount of debt to transfer
     * @param unpaidFees The unpaid fees to transfer
     */
    function transferDebtToBuyer(
        uint256 tokenId,
        address buyer,
        uint256 debtAmount,
        uint256 unpaidFees
    ) external {
        // Only allow calls from buyer's portfolio account
        require(_portfolioFactory.isPortfolio(msg.sender), "Caller must be a portfolio account");
        require(msg.sender == buyer, "Caller must be the buyer");
        
        // Verify token is owned by this portfolio account (seller)
        require(_votingEscrow.ownerOf(tokenId) == address(this), "Token not in seller's portfolio");
        
        // Transfer debt away from seller (this portfolio account)
        CollateralManager.transferDebtAway(address(_portfolioAccountConfig), debtAmount, unpaidFees);
        
        // Remove collateral from seller's collateral manager
        CollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
        CollateralManager.enforceCollateralRequirements();
    }


    /**
     * @notice Buy a 40 Acres listing from an external buyer (not a portfolio account)
     * @param tokenId The token ID being purchased
     * @param buyer The buyer's address
     */
    function buyMarketplaceListing(uint256 tokenId, address buyer) public {
        require(buyer != address(this), "Buyer cannot be this contract");
        require(msg.sender == buyer, "Caller must be buyer");
        CollateralFacet collateralFacet = CollateralFacet(address(this));
        require(_votingEscrow.ownerOf(tokenId) == address(this), "Token not owned by this contract");
        require(collateralFacet.getLockedCollateral(tokenId) > 0, "Token not locked");
        require(collateralFacet.getOriginTimestamp(tokenId) > 0, "Token not originated");
        
        // Ensure buyer is not a portfolio account
        require(!_portfolioFactory.isPortfolio(buyer), "Buyer cannot be a portfolio account");

        // Get listing from user marketplace module
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        
        // Validate listing exists
        require(listing.owner != address(0), "Listing does not exist");
        
        // Ensure listing hasn't expired (0 = never expires)
        require(listing.expiresAt == 0 || listing.expiresAt > block.timestamp, "Listing expired");
        
        // Validate buyer if restricted
        require(listing.allowedBuyer == address(0) || listing.allowedBuyer == buyer, "Buyer not allowed");
        
        // Transfer payment token from buyer to this portfolio account
        IERC20 paymentToken = IERC20(listing.paymentToken);
        paymentToken.safeTransferFrom(buyer, address(this), listing.price);
        
        // Pay down debt if needed
        // Buyer pays listing price, seller receives it (minus debt paid)
        // Excess always goes to seller - buyer agreed to pay the listing price
        uint256 totalDebt = collateralFacet.getTotalDebt();

        if(totalDebt > 0) {
            require(listing.paymentToken == _portfolioAccountConfig.getDebtToken(), "Payment token must be the same as the debt token");
        }
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        address configAddress = address(_portfolioAccountConfig);
        if(totalDebt == 0) {
            // No debt, transfer full listing price to seller
            paymentToken.safeTransfer(portfolioOwner, listing.price);
        } else if (listing.debtAttached == 0) { 
            // no debt attached, pay down debt with listing price transfer excess to seller
            uint256 excess = CollateralManager.decreaseTotalDebt(configAddress, listing.price);
            if(excess > 0) {
                paymentToken.safeTransfer(portfolioOwner, excess);
            }
        } else {
            // Debt attached, transfer full listing price to seller, debt will be transferred separately
            paymentToken.safeTransferFrom(buyer, address(this), listing.debtAttached);
            paymentToken.safeTransfer(portfolioOwner, listing.price);
            uint256 excess = CollateralManager.decreaseTotalDebt(configAddress, listing.debtAttached);
            if(excess > 0) {
                paymentToken.safeTransfer(buyer, excess);
            }
        }
        
        // transfer the NFT to the buyer
        _votingEscrow.transferFrom(address(this), buyer, tokenId);

        // remove collateral from the seller's collateral manager
        CollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
        CollateralManager.enforceCollateralRequirements();
        
        // Remove listing from user marketplace module
        UserMarketplaceModule.removeListing(tokenId);

        emit MarketplaceListingBought(tokenId, buyer, listing.price, listing.debtAttached, portfolioOwner);
    }
}
