// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IVexyOffers {
    struct Offer {
        uint128 budget;
        address buyer;
        uint96 priceMultipler;
        uint128 lockedMin;
        uint128 lockedMax;
        uint128 lockTimeMax;
        uint64 end;
    }

    function offersLength() external view returns (uint256);

    function offers(uint256 offerId)
        external
        view
        returns (
            uint128 budget,
            address buyer,
            uint96 priceMultipler,
            uint128 lockedMin,
            uint128 lockedMax,
            uint128 lockTimeMax,
            uint64 end
        );

    function createOffer(
        uint128 budget,
        uint96 priceMultipler,
        uint128 lockedMin,
        uint128 lockedMax,
        uint128 lockTimeMax,
        uint64 duration,
        uint256 replaceOfferId
    ) external returns (uint256 offerId);

    function removeOffer(uint256 offerId) external returns (bool);

    function sellNFT(uint256 offerId, uint256 nftId) external returns (bool);

    function offerPrice(uint256 offerId, uint256 nftId) external view returns (uint256);
}


