// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IXLoan} from "../../interfaces/IXLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../storage/CollateralStorage.sol";
import {IXRex as IXPhar} from "../../interfaces/IXRex.sol";
import {IVoteModule} from "../../interfaces/IVoteModule.sol";


/**
 * @title XPharFacet
 */
contract XPharFacet {
    PortfolioFactory public immutable _portfolioFactory;
    IERC20 public immutable _phar = IERC20(0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348);
    address public immutable _xphar = 0x0000000000000000000000000000000000000000; // TBD
    address public immutable _voteModule = 0x0000000000000000000000000000000000000000; // TBD

    constructor(address portfolioFactory) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
    }

    function xPharClaimCollateral(address loanContract) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).claimCollateral();
        address asset = address(IXLoan(loanContract)._lockedAsset());
        (uint256 balance, address borrower) = IXLoan(loanContract).getLoanDetails(address(this));
        require(borrower == address(0) && balance == 0);
        CollateralStorage.removeTotalCollateral(asset);
    }

    function xPharIncreaseLoan(address loanContract, uint256 amount) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).increaseLoan(amount);
        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function xPharRequestLoan(address loanContract, uint256 loanAmount, IXLoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        uint256 tokenBalance = IERC20(_phar).balanceOf(msg.sender);
        IERC20(_phar).transferFrom(msg.sender, address(this), tokenBalance);

        // Approve the xPHAR contract to spend the PHAR tokens we just received
        IERC20(_phar).approve(_xphar, tokenBalance);
        address ve = address(IXLoan(loanContract)._lockedAsset());
        IXPhar(_xphar).convertEmissionsToken(tokenBalance);

        IERC20(ve).approve(_voteModule, tokenBalance);
        IVoteModule(_voteModule).depositAll();
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).requestLoan(loanAmount, zeroBalanceOption, increasePercentage, preferredToken, topUp);
        IVoteModule(_voteModule).delegate(address(0));

        CollateralStorage.addTotalCollateral(ve);

        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, loanAmount);

    }

    function xPharUserVote(address loanContract, address[] calldata pools, uint256[] calldata weights) external delegateToLoanContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).userVote(pools, weights);
    }

    function xPharClaim(address loanContract, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external delegateToLoanContract(loanContract) returns (uint256) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        uint256 result = IXLoan(loanContract).claim(fees, tokens, tradeData, allocations);
        return result;
    }

    function xPharVote(address loanContract) external delegateToLoanContract(loanContract) returns (bool) {
        bool success = IXLoan(loanContract).vote(address(this));
        return success;
    }


    modifier delegateToLoanContract(address loanContract) {
        IVoteModule(_voteModule).delegate(address(loanContract));
        _;
        IVoteModule(_voteModule).delegate(address(0));
    }
}