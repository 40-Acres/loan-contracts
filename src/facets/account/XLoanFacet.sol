// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IXLoan} from "../../interfaces/IXLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../storage/CollateralStorage.sol";

/**
 * @title XLoanFacet
 * @dev Middleware facet that interfaces with the loan contract
 */
contract XLoanFacet {
    PortfolioFactory public immutable portfolioFactory;
    CollateralStorage public immutable collateralStorage;

    constructor(address _portfolioFactory, address _collateralStorage) {
        require(_portfolioFactory != address(0));
        portfolioFactory = PortfolioFactory(_portfolioFactory);
        collateralStorage = CollateralStorage(_collateralStorage);
    }

    function claimCollateral(address loanContract) external {
        IXLoan(loanContract).claimCollateral();
        address asset = address(IXLoan(loanContract)._ve());
        (uint256 balance, address borrower) = IXLoan(loanContract).getLoanDetails();
        // ensure the token doesnt have a loan within the loan contract
        require(borrower == address(0) && balance == 0);
        CollateralStorage(collateralStorage).removeTotalCollateral(asset);
    }

    function increaseLoan(address loanContract, uint256 amount) external {
        IXLoan(loanContract).increaseLoan(amount);
        address asset = address(IXLoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function requestLoan(address loanContract, uint256 amount, IXLoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external {
        IXLoan(loanContract).requestLoan(amount, zeroBalanceOption, increasePercentage, preferredToken, topUp);
        address asset = address(IXLoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);

        address ve = address(IXLoan(loanContract)._ve());
        CollateralStorage(collateralStorage).addTotalCollateral(ve);

    }

    function vote(address loanContract) external returns (bool success) {
        address ve = address(IXLoan(loanContract)._ve());
        IERC721(ve).setApprovalForAll(address(loanContract), true);
        success = IXLoan(loanContract).vote();
        IERC721(ve).setApprovalForAll(address(loanContract), false);
    }

    function userVote(address loanContract, address[] calldata pools, uint256[] calldata weights) external {
        address ve = address(IXLoan(loanContract)._ve());
        IERC721(ve).setApprovalForAll(address(loanContract), true);
        IXLoan(loanContract).userVote(pools, weights);
        IERC721(ve).setApprovalForAll(address(loanContract), false);
    }

    function claim(address loanContract, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external returns (uint256) {
        address ve = address(IXLoan(loanContract)._ve());
        IERC721(ve).setApprovalForAll(address(loanContract), true);
        uint256 result = IXLoan(loanContract).claim(fees, tokens, tradeData, allocations);
        IERC721(ve).setApprovalForAll(address(loanContract), false);
        return result;
    }
}