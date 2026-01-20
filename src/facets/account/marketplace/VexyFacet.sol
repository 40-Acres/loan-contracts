// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVexyMarketplace} from "../../../interfaces/external/IVexyMarketplace.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "../utils/AccessControl.sol";
import { CollateralManager } from "../collateral/CollateralManager.sol";
import { IVotingEscrow } from "../../../interfaces/IVotingEscrow.sol";
import { PortfolioAccountConfig } from "../config/PortfolioAccountConfig.sol";
import { SwapMod } from "../swap/SwapMod.sol";

contract VexyFacet is AccessControl {
    using SafeERC20 for IERC20;
    IVexyMarketplace public immutable _vexy = IVexyMarketplace(0x6b478209974BD27e6cf661FEf86C68072b0d6738);
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    PortfolioFactory public immutable _portfolioFactory;
    IVotingEscrow public immutable _votingEscrow;

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) {
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
    }

    function buyVexyListing(uint256 listingId, address buyer) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(buyer != address(this), "Buyer cannot be the portfolio account");

        (
            ,
            ,
            ,
            uint256 nftId,
            address currency,
            ,
            ,
            ,
            ,
            ,
            uint64 soldTime
        ) = _vexy.listings(listingId);
        require(soldTime == 0, "Listing sold");

        uint256 price = _vexy.listingPrice(listingId);
        require(price > 0, "Invalid listing price");
        
        // Check if portfolio owner has sufficient balance and approval
        IERC20 currencyToken = IERC20(currency);
        require(currencyToken.balanceOf(buyer) >= price, "Insufficient balance");
        require(currencyToken.allowance(buyer, address(this)) >= price, "Insufficient allowance");
        
        // transfer funds from portfolio owner to this contract
        currencyToken.safeTransferFrom(buyer, address(this), price);
        // approve the marketplace to spend the funds
        currencyToken.approve(address(_vexy), price);
        // buy the listings
        _vexy.buyListing(listingId);
        // add the collateral to the collateral manager
        CollateralManager.addLockedCollateral(address(_portfolioAccountConfig), nftId, address(_votingEscrow));
    }
}

