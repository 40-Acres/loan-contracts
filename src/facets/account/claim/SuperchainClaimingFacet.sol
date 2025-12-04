// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ClaimingFacet} from "./ClaimingFacet.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SuperchainClaimingFacet is ClaimingFacet, AccessControl {
    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig)
        ClaimingFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, voter, rewardsDistributor, loanConfig)
    {
    }


    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) public override onlyAuthorizedCaller(_portfolioFactory) {
        // get tx.origin weth balance
        uint256 preWethBalance = IERC20(address(0x4200000000000000000000000000000000000006)).balanceOf(tx.origin);
        super.claimFees(fees, tokens, tokenId);
        uint256 postWethBalance = IERC20(address(0x4200000000000000000000000000000000000006)).balanceOf(tx.origin);

        // any difference balance should be sent from this address
        uint256 difference = preWethBalance - postWethBalance;
        if(difference > 0) {
            uint256 portfolioWethBalance = IERC20(address(0x4200000000000000000000000000000000000006)).balanceOf(address(this));
            // if the difference is greater than the portfolio weth balance, send the entire portfolio weth balance
            if(difference > portfolioWethBalance) {
                difference = portfolioWethBalance;
            }
            IERC20(address(0x4200000000000000000000000000000000000006)).transfer(tx.origin, difference);
        }
    }
}