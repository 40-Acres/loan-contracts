// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";

/**
 * @title LoanFacet
 * @dev Middleware facet that interfaces with the loan contract
 */
contract LoanFacet {
    PortfolioFactory public immutable portfolioFactory;
    

    constructor(address _PortfolioFactory) {
        require(_PortfolioFactory != address(0));
        portfolioFactory = PortfolioFactory(_PortfolioFactory);
    }

    function claimCollateral(address loanContract, uint256 tokenId) external {
        ILoan(loanContract).claimCollateral(tokenId);
        address asset = address(ILoan(loanContract)._ve());
        (uint256 balance, address borrower) = ILoan(loanContract).getLoanDetails(tokenId);
        // ensure the token doesnt have a loan within the loan contract
        require(borrower == address(0) && balance == 0);
        IVotingEscrow(asset).transferFrom(address(this), msg.sender, tokenId);
    }

    function increaseLoan(address loanContract, uint256 tokenId, uint256 amount) external {
        ILoan(loanContract).increaseLoan(tokenId, amount);
        address asset = address(ILoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function requestLoan(address loanContract, uint256 tokenId, uint256 amount, ILoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp, bool optInCommunityRewards) external {
        ILoan(loanContract).requestLoan(tokenId, amount, zeroBalanceOption, increasePercentage, preferredToken, topUp, optInCommunityRewards);
        address asset = address(ILoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);
    }

    function vote(address loanContract, uint256 tokenId) external returns (bool success) {
        IERC721(address(ILoan(loanContract)._ve())).setApprovalForAll(address(loanContract), true);
        success = ILoan(loanContract).vote(tokenId);
        IERC721(address(ILoan(loanContract)._ve())).setApprovalForAll(address(loanContract), false);
    }

    function userVote(address loanContract, uint256[] calldata tokenIds, address[] calldata pools, uint256[] calldata weights) external {
        IERC721(address(ILoan(loanContract)._ve())).setApprovalForAll(address(loanContract), true);
        ILoan(loanContract).userVote(tokenIds, pools, weights);
        IERC721(address(ILoan(loanContract)._ve())).setApprovalForAll(address(loanContract), false);
    }

    function claim(address loanContract, uint256 tokenId, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external {
        IERC721(address(ILoan(loanContract)._ve())).setApprovalForAll(address(loanContract), true);
        ILoan(loanContract).claim(tokenId, fees, tokens, tradeData, allocations);
        IERC721(address(ILoan(loanContract)._ve())).setApprovalForAll(address(loanContract), false);
    }

}