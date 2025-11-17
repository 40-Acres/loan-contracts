// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IXLoan} from "../../interfaces/IXLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
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
    IERC4626 public immutable _rex33 = IERC4626(0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4);
    address public immutable _xrex = 0xc93B315971A4f260875103F5DA84cB1E30f366Cc;
    address public immutable _voteModule = 0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1;
    
    address public immutable _voter = 0x942117Ec0458a8AA08669E94B52001Bd43F889C1;
    address public constant _odosRouter = 0x2d8879046f1559E53eb052E949e9544bCB72f414;

    constructor(address portfolioFactory, address accountConfigStorage) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
    }

    function xRexClaimCollateral(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        
        address lockedAsset = address(IXLoan(loanContract)._lockedAsset());
        IVoteModule(_voteModule).withdraw(amount);
        IXLoan(loanContract).confirmClaimCollateral(_xrex);

        if(IVoteModule(_voteModule).balanceOf(address(this)) == 0) {
            address asset = address(IXLoan(loanContract)._lockedAsset());
            CollateralStorage.removeTotalCollateral(asset);
        }

        IERC20(lockedAsset).approve(address(_rex33), amount);
        uint256 assets = _rex33.deposit(amount, address(this));
        _rex33.transfer(msg.sender, assets);
    }

    function xRexIncreaseLoan(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).increaseLoan(amount);
    }

    function xRexIncreaseCollateral(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        _rex33.transferFrom(msg.sender, address(this), amount);
        _increaseCollateral(amount, address(IXLoan(loanContract)._lockedAsset()));
    }
    
    function xRexRequestLoan(uint256 collateralAmount, address loanContract, uint256 loanAmount, IXLoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));

        address lockedAsset = address(IXLoan(loanContract)._lockedAsset());

        _rex33.transferFrom(msg.sender, address(this), collateralAmount);

        _rex33.approve(_voteModule, collateralAmount);
        uint256 assets = _rex33.redeem(collateralAmount, address(this), address(this));
        IERC20(lockedAsset).approve(_voteModule, assets);
        IVoteModule(_voteModule).deposit(assets);
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).requestLoan(loanAmount, zeroBalanceOption, increasePercentage, preferredToken, topUp);
        IVoteModule(_voteModule).delegate(address(0));

        CollateralStorage.addTotalCollateral(lockedAsset);

    }

    function xRexUserVote(address loanContract, address[] calldata pools, uint256[] calldata weights) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).userVote(pools, weights);
        IVoteModule(_voteModule).delegate(address(0));
    }
    
    function xRexClaim(address loanContract, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external onlyApprovedContract(loanContract) returns (uint256) {
        require(_accountConfigStorage.isAuthorizedCaller(msg.sender));

        uint256 beginningUnderlyingAssetBalance = _rex33.balanceOf(address(this));

        // claim the rewards
        uint256 result = IXLoan(loanContract).claim(fees, tokens, tradeData, allocations[0]);

        // increase the collateral if necessary
        if(allocations[1] > 0) {
            // amount we can increase is the difference between the beginning and ending locked asset balance
            uint256 rexAmount = _rex33.balanceOf(address(this)) - beginningUnderlyingAssetBalance;
            _increaseCollateral(rexAmount, address(IXLoan(loanContract)._lockedAsset()));
        }

        return result;
    }

    function xRexProcessRewards(
        address[] calldata gauges,
        address[][] calldata tokens,
        bytes calldata tradeData
    ) virtual public onlyApprovedContract(msg.sender)  {
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
                token.approve(_odosRouter, type(uint256).max);
            }
        }

        IXVoter(_voter).claimIncentives(address(this), gauges, tokens);
        if (tradeData.length == 0) {
            revert(); // No trade data provided, cannot proceed with claiming rewards
        }

        (bool success,) = _odosRouter.call{value: 0}(tradeData);
        require(success);

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
            IERC20 token = IERC20(tokens[i][j]);
            uint256 tokenBalance = token.balanceOf(address(this));
            require(tokenBalance >= tokenBalances[i][j]);
            if (token.allowance(address(this), _odosRouter) != 0) {
                    token.approve(_odosRouter, 0);
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

    function _increaseCollateral(uint256 amount, address lockedAsset) internal {
        _rex33.approve(_voteModule, amount);
        uint256 assetsReceived = _rex33.redeem(amount, address(this), address(this));
        IERC20(lockedAsset).approve(_voteModule, assetsReceived);
        IVoteModule(_voteModule).deposit(assetsReceived);
    }


    modifier onlyApprovedContract(address destination) {
        require(_accountConfigStorage.isApprovedContract(destination));
        _;
    }
    
    function xRexSetIncreasePercentage(address loanContract, uint256 increasePercentage) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setIncreasePercentage(address(this), increasePercentage);
    }

    function xRexSetPreferredToken(address loanContract, address preferredToken) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setPreferredToken(preferredToken);
    }

    function xRexSetTopUp(address loanContract, bool topUp) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setTopUp(topUp);
    }

    function xRexSetZeroBalanceOption(address loanContract, IXLoan.ZeroBalanceOption zeroBalanceOption) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setZeroBalanceOption(zeroBalanceOption);
    }
}