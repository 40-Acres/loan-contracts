// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IOpenXSwap} from "../../../interfaces/external/IOpenXSwap.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControl } from "../utils/AccessControl.sol";
import { CollateralManager } from "../collateral/CollateralManager.sol";
import { IVotingEscrow } from "../../../interfaces/IVotingEscrow.sol";
import { PortfolioAccountConfig } from "../config/PortfolioAccountConfig.sol";

contract OpenXFacet is AccessControl {
    IOpenXSwap public immutable _openx = IOpenXSwap(0xbDdCf6AB290E7Ad076CA103183730d1Bf0661112);
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    PortfolioFactory public immutable _portfolioFactory;
    IVotingEscrow public immutable _votingEscrow;

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) {
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
    }

    function buyOpenXListing(uint256 listingId) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));

        (
            address veNft,
            ,
            ,
            uint256 nftId,
            address currency,
            uint256 price,
            ,
            ,
            uint256 sold
        ) = _openx.Listings(listingId);
        require(sold == 0, "Listing sold");
        require(price > 0, "Invalid listing price");

        // Check if portfolio owner has sufficient balance and approval
        IERC20 currencyToken = IERC20(currency);
        require(currencyToken.balanceOf(portfolioOwner) >= price, "Insufficient balance");
        require(currencyToken.allowance(portfolioOwner, address(this)) >= price, "Insufficient allowance");
        
        // transfer funds from portfolio owner to this contract
        currencyToken.transferFrom(portfolioOwner, address(this), price);
        // approve the marketplace to spend the funds
        currencyToken.approve(address(_openx), price);
        // buy the listing
        _openx.buyNFT(listingId);
        // add the collateral to the collateral manager
        CollateralManager.addLockedCollateral(address(_portfolioAccountConfig), nftId, address(_votingEscrow));
    }
}