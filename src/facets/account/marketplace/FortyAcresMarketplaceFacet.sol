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
 *      40 Acres portfolio accounts. Follows the same pattern as OpenXFacet/VexyFacet:
 *      pulls payment from buyer EOA, approves marketplace, calls purchaseListing.
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
     * @dev Only callable via PortfolioManager.multicall. Pulls payment from buyer EOA,
     *      approves PortfolioMarketplace, then calls purchaseListing which handles
     *      processPayment on the seller and finalizePurchase on the buyer.
     * @param sellerPortfolio The seller's portfolio account address
     * @param tokenId The token ID being purchased
     * @param buyer The buyer's EOA address (must own this portfolio)
     */
    function buyFortyAcresListing(
        uint256 tokenId,
        uint256 sellerPortfolio,
        uint256 nonce,
        address buyer
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(buyer != address(this), "Buyer cannot be the portfolio account");

        // Read listing from seller
        IMarketplaceFacet sellerFacet = IMarketplaceFacet(sellerPortfolio);
        uint256 price = sellerFacet.getListing(tokenId).price;
        address paymentTokenAddr = sellerFacet.getListing(tokenId).paymentToken;
        require(price > 0, "Listing does not exist");

        IERC20 paymentToken = IERC20(paymentTokenAddr);
        require(paymentToken.balanceOf(buyer) >= price, "Insufficient balance");
        require(paymentToken.allowance(buyer, address(this)) >= price, "Insufficient allowance");

        // Pull funds from buyer EOA to this portfolio
        paymentToken.safeTransferFrom(buyer, address(this), price);

        // Approve marketplace to pull payment
        paymentToken.approve(address(_marketplace), price);

        _marketplace.purchaseListing(sellerPortfolio, tokenId, paymentTokenAddr, price);

        // Clear remaining approval
        paymentToken.approve(address(_marketplace), 0);
    }
}
