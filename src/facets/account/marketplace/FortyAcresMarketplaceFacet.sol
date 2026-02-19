// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IMarketplaceFacet} from "../../../interfaces/IMarketplaceFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {PortfolioMarketplace} from "../../marketplace/PortfolioMarketplace.sol";

/**
 * @title FortyAcresMarketplaceFacet
 * @dev Facet that enables portfolio accounts to purchase listings from other
 *      40 Acres portfolio accounts. Uses internal portfolio balance (funded via
 *      borrowTo), approves marketplace, calls purchaseListing.
 *      Uses PortfolioManager multicall so enforceCollateralRequirements is
 *      called on the buyer after the purchase completes.
 */
contract FortyAcresMarketplaceFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    PortfolioMarketplace public immutable _marketplace;

    constructor(
        address portfolioFactory,
        address portfolioAccountConfig,
        address votingEscrow,
        address marketplace
    ) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(votingEscrow != address(0));
        require(marketplace != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _marketplace = PortfolioMarketplace(marketplace);
    }

    /**
     * @notice Buy a listing from another 40 Acres portfolio account
     * @dev Only callable via PortfolioManager.multicall. Reads listing from
     *      PortfolioMarketplace, uses internal balance, approves marketplace,
     *      then calls purchaseListing which handles receiveSaleProceeds on the seller.
     * @param tokenId The token ID being purchased
     * @param nonce The listing nonce for frontrunning protection
     */
    function buyFortyAcresListing(
        uint256 tokenId,
        uint256 nonce
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        // Read listing from PortfolioMarketplace (centralized storage)
        PortfolioMarketplace.Listing memory listing = _marketplace.getListing(tokenId);
        require(listing.price > 0, "Listing does not exist");

        uint256 price = listing.price;
        IERC20 paymentToken = IERC20(listing.paymentToken);

        require(paymentToken.balanceOf(address(this)) >= price, "Insufficient balance");

        // Approve marketplace to pull payment
        paymentToken.approve(address(_marketplace), price);

        // Purchase through marketplace — nonce prevents frontrunning
        _marketplace.purchaseListing(tokenId, nonce);

        // Clear remaining approval
        paymentToken.approve(address(_marketplace), 0);
    }
}
