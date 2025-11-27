// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../storage/CollateralStorage.sol";
import {IXRex} from "../../interfaces/IXRex.sol";
import {IVoteModule} from "../../interfaces/IVoteModule.sol";
import {AccountConfigStorage} from "../../storage/AccountConfigStorage.sol";
import {IXVoter} from "../../interfaces/IXVoter.sol";



/**
 * @title LoanFacet
 */
contract LoanFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    address public immutable _loanContract;


    constructor(address portfolioFactory, address accountConfigStorage, address loanContract) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _loanContract = loanContract;
    }

    function claimCollateral(uint256 tokenId, uint256 amount) external onlyToLoanContract {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        ILoan(_loanContract).claimCollateral(tokenId);
    }

    function increaseLoan(uint256 tokenId, uint256 amount) external onlyToLoanContract {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        ILoan(_loanContract).increaseLoan(tokenId, amount);
    }

    function increaseCollateral(uint256 tokenId, uint256 amount) external onlyToLoanContract {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        // TODO: Implement
    }
    
    function requestLoan(uint256 tokenId, uint256 amount, ILoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external onlyToLoanContract {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        // TODO: Implement
    }

    function userVote(uint256[] calldata tokenIds, address[] calldata pools, uint256[] calldata weights) external onlyToLoanContract {
        ILoan(_loanContract).userVote(tokenIds, pools, weights);
    }


    function vote(uint256 tokenId) external onlyToLoanContract returns (bool) {
        ILoan(_loanContract).vote(tokenId);
    }

    function setIncreasePercentage(uint256 tokenId, uint256 increasePercentage) external onlyToLoanContract {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        ILoan(_loanContract).setIncreasePercentage(tokenId, increasePercentage);
    }

    function setPreferredToken(uint256 tokenId, address preferredToken) external onlyToLoanContract {
        ILoan(_loanContract).setPreferredToken(tokenId, preferredToken);
    }

    function setTopUp(uint256 tokenId, bool topUp) external onlyToLoanContract {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        ILoan(_loanContract).setTopUp(tokenId, topUp);
    }

    function setZeroBalanceOption(uint256 tokenId, ILoan.ZeroBalanceOption zeroBalanceOption) external onlyToLoanContract {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        ILoan(_loanContract).setZeroBalanceOption(tokenId, zeroBalanceOption);
    }

    modifier onlyToLoanContract {
        require(msg.sender == _loanContract);
        _;
    }
}