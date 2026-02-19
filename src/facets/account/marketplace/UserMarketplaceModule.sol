// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title UserMarketplaceModule
 * @dev Minimal sale authorization stored per-portfolio. The full listing
 *      lives in PortfolioMarketplace; this module only records the
 *      portfolio's local consent to sell a given tokenId at a given price.
 */
library UserMarketplaceModule
{
    struct SaleAuthorization {
        uint256 price;
        address paymentToken;
    }

    struct UserMarketplaceModuleData {
        mapping(uint256 => SaleAuthorization) saleAuthorizations; // tokenId => authorization
    }

    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.UserMarketplaceModule");

    function _getUserMarketplaceModuleData() internal pure returns (UserMarketplaceModuleData storage data) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    function createSaleAuthorization(uint256 tokenId, uint256 price, address paymentToken) external {
        require(price > 0, "Price must be > 0");
        UserMarketplaceModuleData storage data = _getUserMarketplaceModuleData();
        data.saleAuthorizations[tokenId] = SaleAuthorization(price, paymentToken);
    }

    function getSaleAuthorization(uint256 tokenId) external view returns (SaleAuthorization memory) {
        return _getUserMarketplaceModuleData().saleAuthorizations[tokenId];
    }

    function hasSaleAuthorization(uint256 tokenId) external view returns (bool) {
        return _getUserMarketplaceModuleData().saleAuthorizations[tokenId].price > 0;
    }

    function removeSaleAuthorization(uint256 tokenId) external {
        UserMarketplaceModuleData storage data = _getUserMarketplaceModuleData();
        require(data.saleAuthorizations[tokenId].price > 0, "No sale authorization");
        delete data.saleAuthorizations[tokenId];
    }
}
