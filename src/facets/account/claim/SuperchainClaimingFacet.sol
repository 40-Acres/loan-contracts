// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ClaimingFacet} from "./ClaimingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SuperchainClaimingFacet is ClaimingFacet {
    address public immutable _weth;

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig, address swapConfig, address vault, address weth)
        ClaimingFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, voter, rewardsDistributor, loanConfig, swapConfig, vault)
    {
        _weth = weth;
    }


    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) public override {
        // get tx.origin weth balance
        uint256 preWethBalance = IERC20(_weth).balanceOf(msg.sender);
        super.claimFees(fees, tokens, tokenId);
        uint256 postWethBalance = IERC20(_weth).balanceOf(msg.sender);

        // any difference balance should be sent from this address
        uint256 difference = preWethBalance - postWethBalance;
        if(difference > 0) {
            uint256 portfolioWethBalance = IERC20(_weth).balanceOf(address(this));
            // if the difference is greater than the portfolio weth balance, send the entire portfolio weth balance
            if(difference > portfolioWethBalance) {
                difference = portfolioWethBalance;
            }
            IERC20(_weth).transfer(msg.sender, difference);
        }
    }
}