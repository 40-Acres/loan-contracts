// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../accounts/PortfolioManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMarketplaceFacet} from "../../interfaces/IMarketplaceFacet.sol";
import {ICollateralFacet} from "../account/collateral/ICollateralFacet.sol";
import {UserMarketplaceModule} from "../account/marketplace/UserMarketplaceModule.sol";

/**
 * @title PortfolioMarketplace
 * @dev Marketplace contract for portfolio account listings
 * Handles taking funds from buyers and calling portfolio account's processPayment function
 */
contract PortfolioMarketplace is Ownable, ReentrancyGuard {
    PortfolioManager public immutable portfolioManager;
    IVotingEscrow public immutable votingEscrow;
    uint256 public protocolFeeBps;
    address public feeRecipient;
    
    event ListingPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed sellerPortfolio,
        uint256 price,
        uint256 protocolFee
    );
    
    error InvalidListing();
    error ListingExpired();
    error BuyerNotAllowed();
    error PaymentAmountMismatch();
    error InsufficientPayment();
    error TransferFailed();
    error InvalidPortfolio();
    
    constructor(
        address _portfolioManager,
        address _votingEscrow,
        uint256 _protocolFeeBps,
        address _feeRecipient
    ) Ownable(msg.sender) {
        require(_portfolioManager != address(0), "Invalid portfolio manager");
        require(_votingEscrow != address(0), "Invalid voting escrow");
        require(_feeRecipient != address(0), "Invalid fee recipient");

        portfolioManager = PortfolioManager(_portfolioManager);
        votingEscrow = IVotingEscrow(_votingEscrow);
        feeRecipient = _feeRecipient;
        protocolFeeBps = _protocolFeeBps;
    }
    
    /**
     * @notice Set protocol fee in basis points
     * @param _protocolFeeBps New protocol fee (max 1000 = 10%)
     */
    function setProtocolFee(uint256 _protocolFeeBps) external onlyOwner {
        require(_protocolFeeBps <= 1000, "Fee too high");
        protocolFeeBps = _protocolFeeBps;
    }
    
    function protocolFee() external view returns (uint256) {
        return protocolFeeBps;
    }
    /**
     * @notice Set fee recipient address
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @notice Get listing details from a portfolio account
     * @param portfolioAccount The portfolio account address
     * @param tokenId The token ID
     * @return listing The listing details
     */
    function getListing(address portfolioAccount, uint256 tokenId) 
        external 
        view 
        returns (UserMarketplaceModule.Listing memory listing) 
    {
        require(portfolioManager.isPortfolioRegistered(portfolioAccount), "Invalid portfolio");
        return IMarketplaceFacet(portfolioAccount).getListing(tokenId);
    }
    
    /**
     * @notice Purchase a listing from a portfolio account
     * @param portfolioAccount The portfolio account that owns the listing
     * @param tokenId The token ID being purchased
     * @param paymentToken The token being used for payment (must match listing)
     * @param paymentAmount The amount to pay (must match listing price)
     */
    function purchaseListing(
        address portfolioAccount,
        uint256 tokenId,
        address paymentToken,
        uint256 paymentAmount
    ) external nonReentrant {
        // Only callable by a registered portfolio account (cross-factory safe)
        require(portfolioManager.isPortfolioRegistered(msg.sender), "Only portfolio accounts can call");

        // msg.sender is the buyer's portfolio (called from FortyAcresMarketplaceFacet via diamond)
        address buyerPortfolio = msg.sender;

        // Resolve the buyer EOA via PortfolioManager (cross-factory safe)
        address buyerFactory = portfolioManager.getFactoryForPortfolio(buyerPortfolio);
        address buyerEoa = PortfolioFactory(buyerFactory).ownerOf(buyerPortfolio);

        // Validate seller portfolio account (cross-factory safe)
        require(portfolioManager.isPortfolioRegistered(portfolioAccount), InvalidPortfolio());

        // Get listing from portfolio account
        UserMarketplaceModule.Listing memory listing = this.getListing(portfolioAccount, tokenId);

        // Validate listing exists
        if (listing.owner == address(0)) {
            revert InvalidListing();
        }

        // Validate listing has valid nonce (only highest nonce listing is purchasable)
        if (!IMarketplaceFacet(portfolioAccount).isListingValid(tokenId)) {
            revert InvalidListing();
        }

        // Validate listing hasn't expired
        if (listing.expiresAt > 0 && listing.expiresAt <= block.timestamp) {
            revert ListingExpired();
        }

        // Validate buyer if restricted (check both portfolio and EOA)
        if (listing.allowedBuyer != address(0) && listing.allowedBuyer != buyerEoa && listing.allowedBuyer != buyerPortfolio) {
            revert BuyerNotAllowed();
        }

        // Validate payment token matches
        require(paymentToken == listing.paymentToken, "Payment token mismatch");

        // Validate payment amount matches listing price
        if (paymentAmount != listing.price) {
            revert PaymentAmountMismatch();
        }

        // Get debt amount from listing (nonce ensures we have the correct listing)
        uint256 debtAmount = listing.debtAttached;

        // Transfer payment from buyer's portfolio to this contract
        IERC20 paymentTokenContract = IERC20(paymentToken);
        require(
            paymentTokenContract.transferFrom(buyerPortfolio, address(this), paymentAmount),
            TransferFailed()
        );

        // Approve seller's portfolio account to take the full payment
        paymentTokenContract.approve(portfolioAccount, paymentAmount);

        // Call seller's processPayment function
        // Pass buyerPortfolio directly so processPayment doesn't need cross-factory lookup
        IMarketplaceFacet(portfolioAccount).processPayment(tokenId, buyerPortfolio, paymentAmount);

        // Clear approval
        paymentTokenContract.approve(portfolioAccount, 0);

        // Finalize purchase: transfer NFT and debt from seller to buyer
        // Always transfer debt (never pay it down automatically)
        IMarketplaceFacet(buyerPortfolio).finalizePurchase(
            portfolioAccount, // seller
            tokenId,
            debtAmount
        );
        
        emit ListingPurchased(
            tokenId,
            buyerEoa,
            portfolioAccount,
            paymentAmount,
            (paymentAmount * protocolFeeBps) / 10000
        );
    }
    
    /**
     * @notice Emergency function to recover tokens sent to this contract
     * @param token The token address to recover
     * @param to The address to send tokens to
     * @param amount The amount to recover
     */
    function recoverTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).transfer(to, amount);
    }
}

