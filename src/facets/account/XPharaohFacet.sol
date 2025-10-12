// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IXLoan} from "../../interfaces/IXLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../storage/CollateralStorage.sol";
import {IXRex} from "../../interfaces/IXRex.sol";
import {IVoteModule} from "../../interfaces/IVoteModule.sol";
import {AccountConfigStorage} from "../../storage/AccountConfigStorage.sol";


import {console} from "forge-std/console.sol";
/**
 * @title XPharaohFacet
 */
contract XPharaohFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IERC20 public immutable _phar = IERC20(0xAAAB9D12A30504559b0C5a9A5977fEE4A6081c6b);
    address public immutable _xphar = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
    address public immutable _voteModule = 0x34F233F868CdB42446a18562710eE705d66f846b;
    address public immutable _entryPoint = 0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA;
    address public immutable _vePhar = 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F;

    constructor(address portfolioFactory, address accountConfigStorage) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
    }

    function pharaohClaimCollateral(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));

        IVoteModule(_voteModule).withdraw(amount);
        uint256 exitAmount = IXRex(_xphar).exit(amount);
        IERC20(_phar).transfer(msg.sender, exitAmount);

        IXLoan(loanContract).confirmClaimCollateral();
        if(IXRex(_xphar).balanceOf(address(this)) == 0) {
            address asset = address(IXLoan(loanContract)._lockedAsset());
            (uint256 balance, address borrower) = IXLoan(loanContract).getLoanDetails(address(this));
            require(borrower == address(0) && balance == 0);
            CollateralStorage.removeTotalCollateral(asset);
        }
    }

    function pharaohIncreaseLoan(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).increaseLoan(amount);
        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function pharaohRequestLoan(address loanContract, uint256 loanAmount, IXLoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        uint256 tokenBalance = IERC20(_phar).balanceOf(msg.sender);
        IERC20(_phar).transferFrom(msg.sender, address(this), tokenBalance);

        // Approve the xREX contract to spend the REX tokens we just received
        IERC20(_phar).approve(_xphar, tokenBalance);
        address lockedAsset = address(IXLoan(loanContract)._lockedAsset());
        IXRex(_xphar).convertEmissionsToken(tokenBalance);

        IERC20(lockedAsset).approve(_voteModule, tokenBalance);
        IVoteModule(_voteModule).depositAll();
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).requestLoan(loanAmount, zeroBalanceOption, increasePercentage, preferredToken, topUp);
        IVoteModule(_voteModule).delegate(address(0));

        CollateralStorage.addTotalCollateral(lockedAsset);

        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, loanAmount);

    }

    function pharaohUserVote(address loanContract, address[] calldata pools, uint256[] calldata weights) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).userVote(pools, weights);
        IVoteModule(_voteModule).delegate(address(0));
    }

    function pharaohClaim(address loanContract, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external onlyApprovedContract(loanContract) returns (uint256) {
        IVoteModule(_voteModule).setAdmin(address(loanContract));
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)) || msg.sender == _entryPoint);
        uint256 result = IXLoan(loanContract).claim(fees, tokens, tradeData, allocations);
        IVoteModule(_voteModule).setAdmin(address(0));
        if(allocations[1] > 0) {
            uint256 rexAmount = _phar.balanceOf(address(this));
            if(allocations[1] < rexAmount) {
                rexAmount = allocations[1];
            }
            _increaseCollateral(rexAmount);
        }
        return result;
    }

    function pharaohVote(address loanContract) external onlyApprovedContract(loanContract) returns (bool) {
        // allow the entry point or the account owner to vote
        IVoteModule(_voteModule).delegate(address(loanContract));
        bool success = IXLoan(loanContract).vote(address(this));
        IVoteModule(_voteModule).delegate(address(0));
        return success;
    }

    // increase the collateral
    function _increaseCollateral(uint256 amount) internal {
        IERC20(_phar).approve(_xphar, amount);
        IXRex(_xphar).convertEmissionsToken(amount);
        IERC20(_xphar).approve(_voteModule, amount);
        IVoteModule(_voteModule).deposit(amount);
    }

    function xPharSetIncreasePercentage(address loanContract, uint256 increasePercentage) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).setIncreasePercentage(increasePercentage);
    }

    function xPharSetPreferredToken(address loanContract, address preferredToken) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).setPreferredToken(preferredToken);
    }

    function xPharSetTopUp(address loanContract, bool topUp) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).setTopUp(topUp);
    }

    function xPharSetZeroBalanceOption(address loanContract, IXLoan.ZeroBalanceOption zeroBalanceOption) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).setZeroBalanceOption(zeroBalanceOption);
    }

    function migratePharaohToXPharaoh(uint256 tokenId) external {
        // require(msg.sender == 0xa0Cb889707d426A7A386870A03bc70d1b0697598); // XPHAR - USDC Contract
        
        // Get the PHAR balance of this account
        uint256 pharBalance = IERC20(_phar).balanceOf(address(this));
        
        if (pharBalance > 0) {
            // Convert PHAR to XPHAR
            // this method has not been released yet
        }
    }

    modifier onlyApprovedContract(address destination) {
        require(_accountConfigStorage.isApprovedContract(destination));
        _;
    }
}