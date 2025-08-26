// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IOpenXSwap {
    /// @notice Emitted when a veNFT is listed (decoded from runtime logs)
    /// @dev Topic0: 0x801e04c818a85406acc72f89a590080611eacb2164e124fd86a28a00c3db5949
    ///      topic1 = seller, topic2 = veNft
    ///      data = (tokenId, currency, price, feeRecipients[], start, end, reservedBuyer, listingId)
    event OpenXListed(
        address indexed seller,
        address indexed veNft,
        uint256 tokenId,
        address currency,
        uint256 price,
        address[] feeRecipients,
        uint256 start,
        uint256 end,
        address reservedBuyer,
        uint256 listingId
    );

    /// @notice Returns listing details for the given listingId
    /// @dev Signature matches on-chain selector for Listings(uint256)
    function Listings(uint256 listingId)
        external
        view
        returns (
            address veNft,
            address seller,
            address reservedBuyer,
            uint256 tokenId,
            address currency,
            uint256 price,
            uint256 startTimestamp,
            uint256 endTimestamp,
            bool sold
        );

    /// @notice Purchase an NFT listing by id
    /// @param listingId The id of the listing to purchase
    function buyNFT(uint256 listingId) external payable;

    /// @notice List an NFT for sale (best-effort signature recovered from bytecode context)
    /// @param veNft The NFT collection address
    /// @param tokenId The NFT token id
    /// @param currency The payment token
    /// @param price The listing price (in currency decimals)
    /// @param feeRecipients Optional fee receivers
    /// @param start Start timestamp
    /// @param end End timestamp
    function listNFT(
        address veNft,
        uint256 tokenId,
        address currency,
        uint256 price,
        address[] calldata feeRecipients,
        uint256 start,
        uint256 end
    ) external;
}


