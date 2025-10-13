// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IXLoan} from "../../interfaces/IXLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../storage/CollateralStorage.sol";
import {IXRex} from "../../interfaces/IXRex.sol";
import {IVoteModule} from "../../interfaces/IVoteModule.sol";
import {AccountConfigStorage} from "../../storage/AccountConfigStorage.sol";
import {IXVoter} from "../../interfaces/IXVoter.sol";
/**
 * @title XRexFacet
 */
contract XRexFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IERC20 public immutable _rex = IERC20(0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348);
    address public immutable _xrex = 0xc93B315971A4f260875103F5DA84cB1E30f366Cc;
    address public immutable _voteModule = 0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1;
    address public immutable _voter = 0x942117Ec0458a8AA08669E94B52001Bd43F889C1;

    constructor(address portfolioFactory, address accountConfigStorage) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
    }

    function xRexClaimCollateral(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));

        IVoteModule(_voteModule).withdraw(amount);
        uint256 exitAmount = IXRex(_xrex).exit(amount);
        IERC20(_rex).transfer(msg.sender, exitAmount);
        IXLoan(loanContract).confirmClaimCollateral();


        if(IVoteModule(_voteModule).balanceOf(address(this)) == 0) {
            address asset = address(IXLoan(loanContract)._lockedAsset());
            CollateralStorage.removeTotalCollateral(asset);
        }
    }

    function xRexIncreaseLoan(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IXLoan(loanContract).increaseLoan(amount);
        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function xRexRequestLoan(address loanContract, uint256 loanAmount, IXLoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external onlyApprovedContract(loanContract) {
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

    function xRexUserVote(address loanContract, address[] calldata pools, uint256[] calldata weights) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).userVote(pools, weights);
        IVoteModule(_voteModule).delegate(address(0));
    }
    
    function xRexClaim(address loanContract, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external onlyApprovedContract(loanContract) returns (uint256) {
        address portfolioOwner = _portfolioFactory.getAccountOwner(address(this));
        require(msg.sender == portfolioOwner || _accountConfigStorage.isAuthorizedCaller(msg.sender));

        // get beginning balance of preferred token and vault asset
        address vaultAsset = address(IXLoan(loanContract)._vaultAsset());
        uint256 beginningAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        uint256 beginningPreferredTokenBalance;
        address lockedAsset = address(IXLoan(loanContract)._lockedAsset());
        uint256 beginningLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        address preferredToken = IXLoan(loanContract).getPreferredToken(address(this));
        if(preferredToken != address(0)) {
            beginningPreferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
        }

        // claim the rewards
        uint256 result = IXLoan(loanContract).claim(fees, tokens, tradeData, allocations);

        // increase the collateral if necessary
        if(allocations[1] > 0) {
            // max amount we can increase is the difference between the beginning and ending locked asset balance
            uint256 rexAmount = _rex.balanceOf(address(this)) - beginningLockedAssetBalance;
            if(allocations[1] < rexAmount) {
                rexAmount = allocations[1];
            }
            _increaseCollateral(rexAmount, address(IXLoan(loanContract)._lockedAsset()));
        }

        // remove any approvals for the assets
        if(preferredToken != address(0)) {
            uint256 preferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
            IERC20(preferredToken).approve(address(msg.sender), 0);
        }
        IERC20(address(IXLoan(loanContract)._vaultAsset())).approve(address(msg.sender), 0);
    
        // return any assets that were gained from the claim to the owner
        if(preferredToken != address(0)) {
            uint256 preferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
            IERC20(preferredToken).transfer(address(portfolioOwner), preferredTokenBalance - beginningPreferredTokenBalance);
        }
        if(IERC20(vaultAsset).balanceOf(address(this)) > beginningAssetBalance) {
            IERC20(vaultAsset).transfer(address(portfolioOwner), IERC20(vaultAsset).balanceOf(address(this)) - beginningAssetBalance);
        }
        return result;
    }

    function xRexProcessRewards(
        address[] calldata gauges,
        address[][] calldata tokens,
        bytes calldata tradeData
    ) virtual public {
        address vaultAsset = address(IXLoan(msg.sender)._vaultAsset());
        uint256 beginningAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        uint256 beginningPreferredTokenBalance;
        address preferredToken = IXLoan(msg.sender).getPreferredToken(address(this));
        if(preferredToken != address(0)) {
            beginningPreferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
        }

        uint256[][] memory tokenBalances = new uint256[][](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenBalances[i] = new uint256[](tokens[i].length);
            for (uint256 j = 0; j < tokens[i].length; j++) {
                IERC20 token = IERC20(tokens[i][j]);
                tokenBalances[i][j] = token.balanceOf(address(this));
                token.approve(0x2d8879046f1559E53eb052E949e9544bCB72f414, type(uint256).max);
            }
        }

        IXVoter(_voter).claimIncentives(address(this), gauges, tokens);
        if (tradeData.length == 0) {
            revert(); // No trade data provided, cannot proceed with claiming rewards
        }

        (bool success,) = 0x2d8879046f1559E53eb052E949e9544bCB72f414.call{value: 0}(tradeData);
        require(success);

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
            IERC20 token = IERC20(tokens[i][j]);
            uint256 tokenBalance = token.balanceOf(address(this));
            require(tokenBalance >= tokenBalances[i][j]);
            if (token.allowance(address(this), 0x2d8879046f1559E53eb052E949e9544bCB72f414) != 0) {
                    token.approve(0x2d8879046f1559E53eb052E949e9544bCB72f414, 0);
                }
            }
        }

        if(preferredToken != address(0)) {
            uint256 preferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
            if(preferredTokenBalance > beginningPreferredTokenBalance) {
                IERC20(preferredToken).transfer(address(msg.sender), preferredTokenBalance - beginningPreferredTokenBalance);
            }
        }
        if(IERC20(vaultAsset).balanceOf(address(this)) > beginningAssetBalance) {
            IERC20(vaultAsset).transfer(address(msg.sender), IERC20(vaultAsset).balanceOf(address(this)) - beginningAssetBalance);
        }
    }

    function xRexVote(address loanContract) external onlyApprovedContract(loanContract) returns (bool) {
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
        IVoteModule(_voteModule).deposit(amount);
    }


    modifier onlyApprovedContract(address destination) {
        require(_accountConfigStorage.isApprovedContract(destination));
        _;
    }
    
}