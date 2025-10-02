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


/**
 * @title XRexFacet
 */
contract XRexFacet {
    PortfolioFactory public immutable _portfolioFactory;
    IERC20 public immutable _rex = IERC20(0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348);
    address public immutable _xrex = 0xc93B315971A4f260875103F5DA84cB1E30f366Cc;
    address public immutable _voteModule = 0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1;
    address public immutable _entryPoint = 0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA;

    constructor(address portfolioFactory) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
    }

    function xRexClaimCollateral(address loanContract) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).claimCollateral();
        address asset = address(IXLoan(loanContract)._lockedAsset());
        (uint256 balance, address borrower) = IXLoan(loanContract).getLoanDetails(address(this));
        require(borrower == address(0) && balance == 0);
        CollateralStorage.removeTotalCollateral(asset);
    }

    function xRexIncreaseLoan(address loanContract, uint256 amount) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).increaseLoan(amount);
        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function xRexRequestLoan(address loanContract, uint256 loanAmount, IXLoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        uint256 tokenBalance = IERC20(_rex).balanceOf(msg.sender);
        IERC20(_rex).transferFrom(msg.sender, address(this), tokenBalance);

        // Approve the xREX contract to spend the REX tokens we just received
        IERC20(_rex).approve(_xrex, tokenBalance);
        address lockedAsset = address(IXLoan(loanContract)._lockedAsset());
        IXRex(_xrex).convertEmissionsToken(tokenBalance);

        IERC20(lockedAsset).approve(_voteModule, tokenBalance);
        IVoteModule(_voteModule).depositAll();
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).requestLoan(loanAmount, zeroBalanceOption, increasePercentage, preferredToken, topUp);
        IVoteModule(_voteModule).delegate(address(0));

        CollateralStorage.addTotalCollateral(lockedAsset);

        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, loanAmount);

    }

    function xRexUserVote(address loanContract, address[] calldata pools, uint256[] calldata weights) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).userVote(pools, weights);
        IVoteModule(_voteModule).delegate(address(0));
    }

    function xRexClaim(address loanContract, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external returns (uint256) {
        IVoteModule(_voteModule).setAdmin(address(loanContract));
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)) || msg.sender == _entryPoint);
        uint256 result = IXLoan(loanContract).claim(fees, tokens, tradeData, allocations);
        IVoteModule(_voteModule).setAdmin(address(0));
        if(allocations[1] > 0) {
            _increaseCollateral(allocations[1], address(IXLoan(loanContract)._lockedAsset()));
        }
        return result;
    }

    function xRexVote(address loanContract) external returns (bool) {
        // allow the entry point or the account owner to vote
        IVoteModule(_voteModule).delegate(address(loanContract));
        bool success = IXLoan(loanContract).vote(address(this));
        IVoteModule(_voteModule).delegate(address(0));
        return success;
    }

    // increase the collateral
    function _increaseCollateral(uint256 amount, address lockedAsset) internal {
        IERC20(_rex).approve(_xrex, amount);
        IXRex(_xrex).convertEmissionsToken(amount);
        IERC20(lockedAsset).approve(_voteModule, amount);
        IVoteModule(_voteModule).depositAll();
    }
}