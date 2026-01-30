// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title UserMarketplaceModule
 
 */
library UserMarketplaceModule
 {
    event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, uint256 debtAttached, uint256 expiresAt, address allowedBuyer);
    event ListingCanceled(uint256 indexed tokenId);
    event ListingSold(uint256 indexed tokenId, address indexed buyer, uint256 price);

    struct Listing {
        address owner;
        uint256 tokenId;
        uint256 price;                    // in paymentToken decimals
        address paymentToken;
        uint256 debtAttached;             // debt amount that should be paid from sale proceeds
        uint256 expiresAt;                // 0 = never
        address allowedBuyer;             // (optional) allowed buyer address
        uint256 nonce;                    // listing nonce - only highest nonce is valid
    }

    // Token storage data using named storage slot
    struct UserMarketplaceModuleData {
        mapping(uint256 => Listing) listings; // tokenId => Listing
        uint256 _offerCounter;
        mapping(uint256 => uint256) listingNonces; // tokenId => current nonce (only highest nonce listing is valid)
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.UserMarketplaceModule");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getUserMarketplaceModuleData() internal pure returns (UserMarketplaceModuleData storage userMarketplaceModuleData) {
        bytes32 position = keccak256("storage.UserMarketplaceModule");
        assembly {
            userMarketplaceModuleData.slot := position
        }
    }

    function createListing(uint256 tokenId, uint256 price, address paymentToken, uint256 debtAttached, uint256 expiresAt, address allowedBuyer) external {
        UserMarketplaceModuleData storage marketplaceConfig = _getUserMarketplaceModuleData();
        // Increment nonce for this tokenId - this invalidates any previous listing
        uint256 newNonce = marketplaceConfig.listingNonces[tokenId] + 1;
        marketplaceConfig.listingNonces[tokenId] = newNonce;
        marketplaceConfig.listings[tokenId] = Listing(msg.sender, tokenId, price, paymentToken, debtAttached, expiresAt, allowedBuyer, newNonce);
        emit ListingCreated(tokenId, msg.sender, price, paymentToken, debtAttached, expiresAt, allowedBuyer);
    }

    function getListing(uint256 tokenId) external view returns (Listing memory) {
        UserMarketplaceModuleData storage marketplaceConfig = _getUserMarketplaceModuleData();
        return marketplaceConfig.listings[tokenId];
    }

    function getCurrentNonce(uint256 tokenId) external view returns (uint256) {
        UserMarketplaceModuleData storage marketplaceConfig = _getUserMarketplaceModuleData();
        return marketplaceConfig.listingNonces[tokenId];
    }

    function isListingValid(uint256 tokenId) external view returns (bool) {
        UserMarketplaceModuleData storage marketplaceConfig = _getUserMarketplaceModuleData();
        Listing memory listing = marketplaceConfig.listings[tokenId];
        // Listing is valid if it exists and has the current (highest) nonce
        return listing.owner != address(0) && listing.nonce == marketplaceConfig.listingNonces[tokenId];
    }

    function removeListing(uint256 tokenId) external {
        UserMarketplaceModuleData storage marketplaceConfig = _getUserMarketplaceModuleData();
        delete marketplaceConfig.listings[tokenId];
        emit ListingCanceled(tokenId);
    }

    function finalizeListing(uint256 tokenId, address buyer, uint256 price) external {
        UserMarketplaceModuleData storage marketplaceConfig = _getUserMarketplaceModuleData();
        delete marketplaceConfig.listings[tokenId];
        emit ListingSold(tokenId, buyer, price);
    }

}