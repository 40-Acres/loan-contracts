// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarket} from "./interfaces/IMarket.sol";
import {ILoan} from "./interfaces/ILoan.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {MarketStorage} from "./MarketStorage.sol";

contract Market is 
    IMarket, 
    Initializable, 
    UUPSUpgradeable, 
    Ownable2StepUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable,
    MarketStorage
{
    using SafeERC20 for IERC20;

    // ============ IMMUTABLE VARIABLES ============
    
    ILoan private immutable _loan;
    IVotingEscrow private immutable _votingEscrow;

    // ============ CONSTANTS ============
    
    uint16 private constant MAX_FEE_BPS = 1000; // 10%

    // ============ ERRORS ============
    
    error InvalidPaymentToken();
    error InvalidExpiration();
    error InvalidFee();
    error ListingNotFound();
    error ListingExpired();
    error Unauthorized();
    error InsufficientPayment();
    error OfferNotFound();
    error OfferExpired();
    error InvalidWeightRange();
    error InvalidLockTime();
    error InsufficientDebtTolerance();
    error InsufficientWeight();
    error ExcessiveWeight();
    error ExcessiveLockTime();

    // ============ CONSTRUCTOR & INITIALIZATION ============

    constructor(address _loanAddress, address _votingEscrowAddress) {
        _loan = ILoan(_loanAddress);
        _votingEscrow = IVotingEscrow(_votingEscrowAddress);
        _disableInitializers();
    }

    function initialize(
        address _owner,
        uint16 _marketFeeBps,
        address _feeRecipient
    ) public initializer {
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        
        _transferOwnership(_owner);
        
        if (_marketFeeBps > MAX_FEE_BPS) revert InvalidFee();
        _setMarketFeeBps(_marketFeeBps);
        _setFeeRecipient(_feeRecipient == address(0) ? _owner : _feeRecipient);
        
        // Set USDC as allowed by default (Base mainnet)
        _setAllowedPaymentToken(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, true);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ============ PUBLIC VIEW FUNCTIONS ============

    function loan() external view returns (address) {
        return address(_loan);
    }

    function marketFeeBps() external view returns (uint16) {
        return _getMarketFeeBps();
    }

    function feeRecipient() external view returns (address) {
        return _getFeeRecipient();
    }

    function isOperatorFor(address owner, address operator) external view returns (bool) {
        return _getIsOperatorFor(owner, operator);
    }

    function allowedPaymentToken(address token) external view returns (bool) {
        return _getAllowedPaymentToken(token);
    }

    // ============ EXTERNAL FUNCTIONS ============

    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external nonReentrant whenNotPaused {
        _makeListing(tokenId, price, paymentToken, expiresAt, msg.sender);
    }

    function _makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address caller
    ) internal {
        if (!_getAllowedPaymentToken(paymentToken)) revert InvalidPaymentToken();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert InvalidExpiration();
        
        // Check if caller can operate this token
        address tokenOwner = _getTokenOwnerOrBorrower(tokenId);
        if (!_canOperate(tokenOwner, caller)) revert Unauthorized();
        
        // If veNFT is not in LoanV2, require it to be deposited first
        if (_votingEscrow.ownerOf(tokenId) == caller) {
            revert("veNFT must be deposited into LoanV2 before listing. Call loan.requestLoan() first.");
        }
        
        // Check for outstanding loan
        (uint256 balance,) = _loan.getLoanDetails(tokenId);
        bool hasOutstandingLoan = balance > 0;
        
        // Create listing using storage
        Listing storage listing = _getListing(tokenId);
        listing.owner = tokenOwner;
        listing.tokenId = tokenId;
        listing.price = price;
        listing.paymentToken = paymentToken;
        listing.hasOutstandingLoan = hasOutstandingLoan;
        listing.expiresAt = expiresAt;
        
        emit ListingCreated(tokenId, tokenOwner, price, paymentToken, hasOutstandingLoan, expiresAt);
    }

    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external nonReentrant whenNotPaused {
        Listing storage listing = _getListing(tokenId);
        if (listing.owner == address(0)) revert ListingNotFound();
        if (!_canOperate(listing.owner, msg.sender)) revert Unauthorized();
        if (!_getAllowedPaymentToken(newPaymentToken)) revert InvalidPaymentToken();
        if (newExpiresAt != 0 && newExpiresAt <= block.timestamp) revert InvalidExpiration();
        
        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.expiresAt = newExpiresAt;
        
        emit ListingUpdated(tokenId, newPrice, newPaymentToken, newExpiresAt);
    }

    function cancelListing(uint256 tokenId) external nonReentrant {
        Listing storage listing = _getListing(tokenId);
        if (listing.owner == address(0)) revert ListingNotFound();
        if (!_canOperate(listing.owner, msg.sender)) revert Unauthorized();
        
        _deleteListing(tokenId);
        emit ListingCancelled(tokenId);
    }

    function takeListing(uint256 tokenId) external payable nonReentrant whenNotPaused {
        _takeListing(tokenId, msg.sender);
    }

    function _takeListing(uint256 tokenId, address buyer) internal {
        Listing memory listing = _getListing(tokenId);
        if (listing.owner == address(0)) revert ListingNotFound();
        if (!_isListingActive(tokenId)) revert ListingExpired();
        
        (uint256 total, uint256 listingPrice, uint256 loanBalance,) = _getTotalCost(tokenId);
        
        // Transfer payment from buyer
        IERC20(listing.paymentToken).safeTransferFrom(buyer, address(this), total);
        
        // Pay off loan if exists
        if (listing.hasOutstandingLoan && loanBalance > 0) {
            IERC20(listing.paymentToken).approve(address(_loan), loanBalance);
            _loan.pay(tokenId, loanBalance);
        }
        
        // Calculate and distribute fees
        uint256 fee = (listingPrice * _getMarketFeeBps()) / 10000;
        uint256 sellerAmount = listingPrice - fee;
        
        if (fee > 0) {
            IERC20(listing.paymentToken).safeTransfer(_getFeeRecipient(), fee);
        }
        IERC20(listing.paymentToken).safeTransfer(listing.owner, sellerAmount);
        
        // Transfer ownership
        _loan.setBorrower(tokenId, buyer);
        
        // Clean up
        _deleteListing(tokenId);
        emit ListingTaken(tokenId, buyer, listingPrice, fee);
    }

    // ============ OFFER FUNCTIONS ============

    function createOffer(
        uint256 minWeight,
        uint256 maxWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 maxLockTime,
        uint256 expiresAt
    ) external payable nonReentrant whenNotPaused {
        if (!_getAllowedPaymentToken(paymentToken)) revert InvalidPaymentToken();
        if (minWeight > maxWeight) revert InvalidWeightRange();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert InvalidExpiration();
        
        // Transfer full offer price from caller
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);
        
        // Create offer
        uint256 offerId = _incrementOfferCounter();
        Offer storage offer = _getOffer(offerId);
        offer.creator = msg.sender;
        offer.minWeight = minWeight;
        offer.maxWeight = maxWeight;
        offer.debtTolerance = debtTolerance;
        offer.price = price;
        offer.paymentToken = paymentToken;
        offer.maxLockTime = maxLockTime;
        offer.expiresAt = expiresAt;
        offer.offerId = offerId;
        
        emit OfferCreated(offerId, msg.sender, minWeight, maxWeight, debtTolerance, price, paymentToken, maxLockTime, expiresAt);
    }

    function updateOffer(
        uint256 offerId,
        uint256 newMinWeight,
        uint256 newMaxWeight,
        uint256 newDebtTolerance,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newMaxLockTime,
        uint256 newExpiresAt
    ) external nonReentrant whenNotPaused {
        Offer storage offer = _getOffer(offerId);
        if (offer.creator == address(0)) revert OfferNotFound();
        if (offer.creator != msg.sender) revert Unauthorized();
        if (!_getAllowedPaymentToken(newPaymentToken)) revert InvalidPaymentToken();
        if (newMinWeight > newMaxWeight) revert InvalidWeightRange();
        if (newExpiresAt != 0 && newExpiresAt <= block.timestamp) revert InvalidExpiration();
        
        // Handle price change
        if (newPrice != offer.price) {
            if (newPrice > offer.price) {
                // Transfer additional amount
                IERC20(newPaymentToken).safeTransferFrom(msg.sender, address(this), newPrice - offer.price);
            } else {
                // Refund excess amount
                IERC20(offer.paymentToken).safeTransfer(msg.sender, offer.price - newPrice);
            }
        }
        
        // Update offer
        offer.minWeight = newMinWeight;
        offer.maxWeight = newMaxWeight;
        offer.debtTolerance = newDebtTolerance;
        offer.price = newPrice;
        offer.paymentToken = newPaymentToken;
        offer.maxLockTime = newMaxLockTime;
        offer.expiresAt = newExpiresAt;
        
        emit OfferUpdated(offerId, newMinWeight, newMaxWeight, newDebtTolerance, newPrice, newPaymentToken, newMaxLockTime, newExpiresAt);
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _getOffer(offerId);
        if (offer.creator == address(0)) revert OfferNotFound();
        if (offer.creator != msg.sender) revert Unauthorized();
        
        // Refund the offer price
        IERC20(offer.paymentToken).safeTransfer(msg.sender, offer.price);
        
        // Delete offer
        _deleteOffer(offerId);
        emit OfferCancelled(offerId);
    }

    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInLoanV2) external nonReentrant whenNotPaused {
        Offer memory offer = _getOffer(offerId);
        if (offer.creator == address(0)) revert OfferNotFound();
        if (!_isOfferActive(offerId)) revert OfferExpired();
        
        // Verify seller owns the veNFT
        address tokenOwner = _getTokenOwnerOrBorrower(tokenId);
        if (!_canOperate(tokenOwner, msg.sender)) revert Unauthorized();
        
        // Validate veNFT against offer criteria
        _validateOfferCriteria(tokenId, offer, isInLoanV2);
        
        // Calculate and distribute fees
        uint256 fee = (offer.price * _getMarketFeeBps()) / 10000;
        uint256 sellerAmount = offer.price - fee;
        
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(_getFeeRecipient(), fee);
        }
        IERC20(offer.paymentToken).safeTransfer(msg.sender, sellerAmount);
        
        // Transfer ownership
        if (isInLoanV2) {
            _loan.setBorrower(tokenId, offer.creator);
        } else {
            // Transfer from wallet to offer creator
            _votingEscrow.transferFrom(msg.sender, offer.creator, tokenId);
        }
        
        // Delete offer
        _deleteOffer(offerId);
        emit OfferAccepted(offerId, tokenId, msg.sender, offer.price, fee);
    }

    function matchOfferWithListing(uint256 offerId, uint256 tokenId) external nonReentrant whenNotPaused {
        Offer memory offer = _getOffer(offerId);
        if (offer.creator == address(0)) revert OfferNotFound();
        if (!_isOfferActive(offerId)) revert OfferExpired();
        
        Listing memory listing = _getListing(tokenId);
        if (listing.owner == address(0)) revert ListingNotFound();
        if (!_isListingActive(tokenId)) revert ListingExpired();
        
        // Validate veNFT against offer criteria
        _validateOfferCriteria(tokenId, offer);
        
        // Calculate and distribute fees
        uint256 fee = (offer.price * _getMarketFeeBps()) / 10000 ;
        uint256 sellerAmount = offer.price - fee;
        
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(_getFeeRecipient(), fee);
        }
        IERC20(offer.paymentToken).safeTransfer(listing.owner, sellerAmount);
        
        // Transfer ownership
        _loan.setBorrower(tokenId, offer.creator);
        
        // Clean up
        _deleteListing(tokenId);
        _deleteOffer(offerId);
        emit OfferMatched(offerId, tokenId, offer.creator, offer.price, fee);
    }

    function setOperatorApproval(address operator, bool approved) external {
        _setIsOperatorFor(msg.sender, operator, approved);
        emit OperatorApproved(msg.sender, operator, approved);
    }

    // ============ VIEW FUNCTIONS ============

    function getListing(uint256 tokenId) external view returns (
        address owner,
        uint256 price,
        address paymentToken,
        bool hasOutstandingLoan,
        uint256 expiresAt
    ) {
        Listing memory listing = _getListing(tokenId);
        return (
            listing.owner,
            listing.price,
            listing.paymentToken,
            listing.hasOutstandingLoan,
            listing.expiresAt
        );
    }

    function getTotalCost(uint256 tokenId) external view returns (
        uint256 total,
        uint256 listingPrice,
        uint256 loanBalance,
        address paymentToken
    ) {
        return _getTotalCost(tokenId);
    }

    function getOffer(uint256 offerId) external view returns (
        address creator,
        uint256 minWeight,
        uint256 maxWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 maxLockTime,
        uint256 expiresAt
    ) {
        Offer memory offer = _getOffer(offerId);
        return (
            offer.creator,
            offer.minWeight,
            offer.maxWeight,
            offer.debtTolerance,
            offer.price,
            offer.paymentToken,
            offer.maxLockTime,
            offer.expiresAt
        );
    }

    function isListingActive(uint256 tokenId) external view returns (bool) {
        return _isListingActive(tokenId);
    }

    function isOfferActive(uint256 offerId) external view returns (bool) {
        return _isOfferActive(offerId);
    }

    function canOperate(address owner, address operator) external view returns (bool) {
        return _canOperate(owner, operator);
    }

    // ============ ADMIN FUNCTIONS ============

    function setMarketFee(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert InvalidFee();
        _setMarketFeeBps(bps);
        emit MarketFeeChanged(bps);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        _setFeeRecipient(recipient);
        emit FeeRecipientChanged(recipient);
    }

    function setAllowedPaymentToken(address token, bool allowed) external onlyOwner {
        _setAllowedPaymentToken(token, allowed);
        emit PaymentTokenAllowed(token, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ INTERNAL FUNCTIONS ============

    function _canOperate(address owner, address operator) internal view returns (bool) {
        return owner == operator || _getIsOperatorFor(owner, operator);
    }

    function _getTokenOwnerOrBorrower(uint256 tokenId) internal view returns (address) {
        // First check if it's in LoanV2
        (, address borrower) = _loan.getLoanDetails(tokenId);
        if (borrower != address(0)) {
            return borrower;
        }
        
        // Otherwise check direct ownership
        return _votingEscrow.ownerOf(tokenId);
    }

    function _isListingActive(uint256 tokenId) internal view returns (bool) {
        Listing memory listing = _getListing(tokenId);
        return listing.owner != address(0) && 
               (listing.expiresAt == 0 || block.timestamp < listing.expiresAt);
    }

    function _isOfferActive(uint256 offerId) internal view returns (bool) {
        Offer memory offer = _getOffer(offerId);
        return offer.creator != address(0) && 
               (offer.expiresAt == 0 || block.timestamp < offer.expiresAt);
    }

    function _getTotalCost(uint256 tokenId) internal view returns (
        uint256 total,
        uint256 listingPrice,
        uint256 loanBalance,
        address paymentToken
    ) {
        Listing memory listing = _getListing(tokenId);
        if (listing.owner == address(0)) revert ListingNotFound();
        
        listingPrice = listing.price;
        paymentToken = listing.paymentToken;
        
        if (listing.hasOutstandingLoan) {
            (loanBalance,) = _loan.getLoanDetails(tokenId);
        }
        
        total = listingPrice + loanBalance;
    }

    function _validateOfferCriteria(uint256 tokenId, Offer memory offer) internal view {
        // Get veNFT weight - check if it's in LoanV2 first, otherwise use current VotingEscrow weight
        uint256 weight = _getVeNFTWeight(tokenId);
        
        if (weight < offer.minWeight) revert InsufficientWeight();
        if (weight > offer.maxWeight) revert ExcessiveWeight();
        
        // Get loan balance
        (uint256 loanBalance,) = _loan.getLoanDetails(tokenId);
        if (loanBalance > offer.debtTolerance) revert InsufficientDebtTolerance();
        
        // Get lock time from VotingEscrow
        IVotingEscrow.LockedBalance memory lockedBalance = _votingEscrow.locked(tokenId);
        if (lockedBalance.end > offer.maxLockTime) revert ExcessiveLockTime();
    }

    function _validateOfferCriteria(uint256 tokenId, Offer memory offer, bool isInLoanV2) internal view {
        // Get veNFT weight based on location
        uint256 weight = isInLoanV2 ? _loan.getLoanWeight(tokenId) : _getVeNFTWeight(tokenId);
        
        if (weight < offer.minWeight) revert InsufficientWeight();
        if (weight > offer.maxWeight) revert ExcessiveWeight();
        
        // Get loan balance (same for both cases)
        (uint256 loanBalance,) = _loan.getLoanDetails(tokenId);
        if (loanBalance > offer.debtTolerance) revert InsufficientDebtTolerance();
        
        // Get lock time from VotingEscrow
        IVotingEscrow.LockedBalance memory lockedBalance = _votingEscrow.locked(tokenId);
        if (lockedBalance.end > offer.maxLockTime) revert ExcessiveLockTime();
    }

    function _getVeNFTWeight(uint256 tokenId) internal view returns (uint256) {
        // veNFT is in wallet - use current VotingEscrow weight
        IVotingEscrow.LockedBalance memory lockedBalance = _votingEscrow.locked(tokenId);
        if (!lockedBalance.isPermanent && lockedBalance.end < block.timestamp) {
            return 0;
        }
        require(lockedBalance.amount >= 0);
        return uint256(uint128(lockedBalance.amount));
    }
}