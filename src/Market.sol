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
import {ILoanV2} from "./interfaces/ILoanV2.sol";
import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";
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
    
    ILoanV2 private immutable _loan;
    IVotingEscrow private immutable _votingEscrow;

    // ============ CONSTANTS ============
    
    uint16 private constant MAX_FEE_BPS = 1000; // 10%
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // ============ ERRORS ============
    
    error InvalidPaymentToken();
    error InvalidExpiration();
    error InvalidFee();
    error ListingNotFound();
    error ListingExpired();
    error Unauthorized();
    error InsufficientPayment();
    error FlashLoanFailed();

    // ============ CONSTRUCTOR & INITIALIZATION ============

    constructor(address _loanAddress, address _votingEscrowAddress) {
        _loan = ILoanV2(_loanAddress);
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
        uint256 expiresAt,
        ILoanV2.ZeroBalanceOption zbo
    ) external nonReentrant whenNotPaused {
        if (!_getAllowedPaymentToken(paymentToken)) revert InvalidPaymentToken();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert InvalidExpiration();
        
        // Check if caller can operate this token
        address tokenOwner = _getTokenOwnerOrBorrower(tokenId);
        if (!_canOperate(tokenOwner, msg.sender)) revert Unauthorized();
        
        // If veNFT is not in LoanV2, deposit it first
        if (_votingEscrow.ownerOf(tokenId) == msg.sender) {
            _loan.requestLoan(tokenId, 0, zbo, 0, address(0), false, false);
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
        Listing memory listing = _getListing(tokenId);
        if (listing.owner == address(0)) revert ListingNotFound();
        if (!_isListingActive(tokenId)) revert ListingExpired();
        
        (uint256 total, uint256 listingPrice, uint256 loanBalance,) = _getTotalCost(tokenId);
        
        // Transfer payment from buyer
        IERC20(listing.paymentToken).safeTransferFrom(msg.sender, address(this), total);
        
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
        _loan.transferLoanOwnership(tokenId, msg.sender);
        
        // Clean up
        _deleteListing(tokenId);
        emit ListingTaken(tokenId, msg.sender, listingPrice, fee);
    }

    function borrowAndTake(
        uint256 tokenId,
        uint256 payoffFromBuyer,
        bool useFlashLoan
    ) external payable nonReentrant whenNotPaused {
        Listing memory listing = _getListing(tokenId);
        if (listing.owner == address(0)) revert ListingNotFound();
        if (!_isListingActive(tokenId)) revert ListingExpired();
        if (!listing.hasOutstandingLoan) revert("No outstanding loan");
        
        (uint256 total, uint256 listingPrice, uint256 loanBalance,) = _getTotalCost(tokenId);
        
        if (!useFlashLoan) {
            // Simple case: buyer pays everything
            if (payoffFromBuyer != loanBalance) revert InsufficientPayment();
            this.takeListing(tokenId);
            return;
        }
        
        // Flash loan case
        uint256 flashAmount = loanBalance - payoffFromBuyer;
        uint256 buyerPayment = payoffFromBuyer + listingPrice;
        
        // Transfer buyer payment
        IERC20(listing.paymentToken).safeTransferFrom(msg.sender, address(this), buyerPayment);
        
        // Prepare flash loan data
        bytes memory data = abi.encode(tokenId, msg.sender, listingPrice, payoffFromBuyer);
        
        // Execute flash loan
        bool success = _loan.flashLoan(
            IFlashLoanReceiver(this),
            listing.paymentToken,
            flashAmount,
            data
        );
        
        if (!success) revert FlashLoanFailed();
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

    function isListingActive(uint256 tokenId) external view returns (bool) {
        return _isListingActive(tokenId);
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

    // ============ FLASH LOAN RECEIVER ============

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != address(_loan)) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();
        
        (uint256 tokenId, address buyer, uint256 listingPrice, uint256 payoffFromBuyer) = 
            abi.decode(data, (uint256, address, uint256, uint256));
        
        Listing memory listing = _getListing(tokenId);
        
        // Pay off the loan using flash loan + buyer funds
        uint256 totalPayoff = amount + payoffFromBuyer;
        IERC20(token).approve(address(_loan), totalPayoff);
        _loan.pay(tokenId, totalPayoff);
        
        // Transfer ownership to buyer
        _loan.transferLoanOwnership(tokenId, buyer);
        
        // Re-borrow flash amount for the buyer
        _loan.increaseLoan(tokenId, amount);
        
        // Approve flash loan repayment
        uint256 repayAmount = amount + fee;
        IERC20(token).approve(address(_loan), repayAmount);
        
        // Calculate and distribute listing price fees
        uint256 marketFee = (listingPrice * _getMarketFeeBps()) / 10000;
        uint256 sellerAmount = listingPrice - marketFee;
        
        if (marketFee > 0) {
            IERC20(token).safeTransfer(_getFeeRecipient(), marketFee);
        }
        IERC20(token).safeTransfer(listing.owner, sellerAmount);
        
        // Clean up listing
        _deleteListing(tokenId);
        emit ListingTaken(tokenId, buyer, listingPrice, marketFee);
        
        return CALLBACK_SUCCESS;
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
}