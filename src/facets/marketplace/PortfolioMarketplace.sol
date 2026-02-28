// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {PortfolioManager} from "../../accounts/PortfolioManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMarketplaceFacet} from "../../interfaces/IMarketplaceFacet.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";

/**
 * @title PortfolioMarketplace
 * @dev Centralized marketplace for veNFT listings. Listings are stored here;
 *      portfolio accounts hold only a local SaleAuthorization for consent.
 */
contract PortfolioMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    PortfolioManager public immutable portfolioManager;
    IVotingEscrow public immutable votingEscrow;
    uint256 public protocolFeeBps;
    address public feeRecipient;
    uint256 public nextNonce;
    mapping(address => bool) public allowedPaymentTokens;

    struct Listing {
        address owner;           // seller portfolio address
        uint256 tokenId;
        uint256 price;           // in paymentToken decimals
        address paymentToken;
        uint256 expiresAt;       // 0 = never
        address allowedBuyer;    // (optional) allowed buyer address
        uint256 nonce;           // unique nonce for frontrunning protection
    }

    // tokenId => Listing
    mapping(uint256 => Listing) public listings;
    EnumerableSet.UintSet private _listingIds;

    event ListingCreated(
        address indexed sellerPortfolio,
        uint256 indexed tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer,
        uint256 nonce
    );
    event ListingCanceled(address indexed sellerPortfolio, uint256 indexed tokenId);
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
    error InvalidPortfolio();
    error ListingAlreadyExists();
    error NonceMismatch();

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

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function setProtocolFee(uint256 _protocolFeeBps) external onlyOwner {
        require(_protocolFeeBps <= 1000, "Fee too high");
        protocolFeeBps = _protocolFeeBps;
    }

    function protocolFee() external view returns (uint256) {
        return protocolFeeBps;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }

    function setAllowedPaymentToken(address token, bool allowed) external onlyOwner {
        require(token != address(0), "Invalid token");
        allowedPaymentTokens[token] = allowed;
    }

    // ──────────────────────────────────────────────
    // Listing Management (called by portfolio accounts)
    // ──────────────────────────────────────────────

    /**
     * @notice Create a centralized listing. Only callable by registered portfolio accounts.
     */
    function createListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer
    ) external {
        require(portfolioManager.isPortfolioRegistered(msg.sender), InvalidPortfolio());
        require(allowedPaymentTokens[paymentToken], "Payment token not allowed");
        require(expiresAt == 0 || expiresAt > block.timestamp, "Invalid expiration");
        require(votingEscrow.ownerOf(tokenId) == msg.sender, "Not token owner");
        
        Listing storage existing = listings[tokenId];
        if (existing.owner != address(0)) {
            // Allow overwriting only if expired; active listings must be canceled first
            require(existing.expiresAt > 0 && existing.expiresAt <= block.timestamp, "Listing already exists");
            // Clean up expired listing
            delete listings[tokenId];
        }

        uint256 nonce = nextNonce++;
        listings[tokenId] = Listing({
            owner: msg.sender,
            tokenId: tokenId,
            price: price,
            paymentToken: paymentToken,
            expiresAt: expiresAt,
            allowedBuyer: allowedBuyer,
            nonce: nonce
        });
        _listingIds.add(tokenId);

        emit ListingCreated(msg.sender, tokenId, price, paymentToken, expiresAt, allowedBuyer, nonce);
    }

    /**
     * @notice Cancel a listing. Only callable by the listing owner portfolio.
     */
    function cancelListing(uint256 tokenId) external {
        Listing storage listing = listings[tokenId];
        require(listing.owner == msg.sender, "Not listing owner");
        delete listings[tokenId];
        _listingIds.remove(tokenId);
        emit ListingCanceled(msg.sender, tokenId);
    }

    /**
     * @notice Remove expired listings so tokenIds can be re-listed.
     */
    function cleanExpiredListings(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Listing storage listing = listings[tokenIds[i]];
            if (listing.expiresAt > 0 && listing.expiresAt <= block.timestamp) {
                address owner = listing.owner;
                emit ListingCanceled(owner, tokenIds[i]);
                delete listings[tokenIds[i]];
                _listingIds.remove(tokenIds[i]);
                // Clear the portfolio's local SaleAuthorization to prevent stale data
                // from blocking collateral removal
                IMarketplaceFacet(owner).clearExpiredSaleAuthorization(tokenIds[i]);
            }
        }
    }

    /**
     * @notice Get listing details from centralized storage
     */
    function getListing(uint256 tokenId)
        external
        view
        returns (Listing memory)
    {
        return listings[tokenId];
    }

    /**
     * @notice Purchase a listing.
     * @param tokenId The token ID being purchased
     * @param nonce The listing nonce for frontrunning protection
     */
    function purchaseListing(
        uint256 tokenId,
        uint256 nonce
    ) external nonReentrant {

        // Get listing from centralized storage
        Listing memory listing = listings[tokenId];

        // Validate listing exists
        if (listing.owner == address(0)) {
            revert InvalidListing();
        }

        // Validate nonce matches to prevent frontrunning
        require(listing.nonce == nonce, "Nonce mismatch");

        // Validate listing hasn't expired
        if (listing.expiresAt > 0 && listing.expiresAt <= block.timestamp) {
            revert ListingExpired();
        }

        // Validate buyer if restricted — check both portfolio address and EOA owner
        if (listing.allowedBuyer != address(0)) {
            address buyerFactory = portfolioManager.portfolioToFactory(msg.sender);
            address buyerEoa = PortfolioFactory(buyerFactory).ownerOf(msg.sender);
            if (listing.allowedBuyer != msg.sender && listing.allowedBuyer != buyerEoa) {
                revert BuyerNotAllowed();
            }
        }

        address sellerPortfolio = listing.owner;
        uint256 price = listing.price;
        address paymentToken = listing.paymentToken;

        // Calculate protocol fee
        uint256 fee = (price * protocolFeeBps) / 10000;
        uint256 netPayment = price - fee;

        // Transfer full price from buyer portfolio to this contract
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);

        // Send protocol fee to feeRecipient
        if (fee > 0) {
            IERC20(paymentToken).safeTransfer(feeRecipient, fee);
        }

        // Approve seller portfolio for net payment
        IERC20(paymentToken).approve(sellerPortfolio, netPayment);

        // Call seller's receiveSaleProceeds — pays debt, transfers NFT, sends excess to owner
        IMarketplaceFacet(sellerPortfolio).receiveSaleProceeds(tokenId, msg.sender, netPayment);

        // Clear any remaining approval
        IERC20(paymentToken).approve(sellerPortfolio, 0);

        // Delete listing
        delete listings[tokenId];
        _listingIds.remove(tokenId);

        emit ListingPurchased(tokenId, msg.sender, sellerPortfolio, price, fee);
    }

    // ──────────────────────────────────────────────
    // Listing Enumeration
    // ──────────────────────────────────────────────

    /// @notice Get all listing tokenIds (includes expired listings), paginated
    function getListingIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256 total = _listingIds.length();
        if (offset >= total) {
            return new uint256[](0);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256[] memory result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = _listingIds.at(i);
        }
        return result;
    }

    /// @notice Get the number of listings (includes expired listings)
    function getListingCount() external view returns (uint256) {
        return _listingIds.length();
    }

    /// @notice Get only non-expired listing tokenIds, paginated
    function getActiveListingIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256 total = _listingIds.length();
        if (offset >= total) {
            return new uint256[](0);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256[] memory temp = new uint256[](end - offset);
        uint256 count;
        for (uint256 i = offset; i < end; i++) {
            uint256 tokenId = _listingIds.at(i);
            Listing storage listing = listings[tokenId];
            if (listing.expiresAt == 0 || listing.expiresAt > block.timestamp) {
                temp[count++] = tokenId;
            }
        }
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Get full Listing structs for an array of tokenIds
    function getListings(uint256[] calldata tokenIds) external view returns (Listing[] memory) {
        Listing[] memory result = new Listing[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            result[i] = listings[tokenIds[i]];
        }
        return result;
    }

    // ──────────────────────────────────────────────
    // Emergency
    // ──────────────────────────────────────────────

    function recoverTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
