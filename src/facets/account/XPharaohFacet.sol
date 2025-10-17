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



interface PharaohMigrator {
    function migrateVe(uint256 _tokenID) external;
}


/**
 * @title XPharaohFacet
 */
contract XPharaohFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IERC4626 public immutable _rex33 = IERC4626(0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9);
    address public immutable _xrex = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
    address public immutable _voteModule = 0x34F233F868CdB42446a18562710eE705d66f846b;
    address public immutable _voter = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7;
    address public immutable _vePhar = 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F;

    constructor(address portfolioFactory, address accountConfigStorage) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
    }

    function xPharClaimCollateral(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        // require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        
        // address lockedAsset = address(IXLoan(loanContract)._lockedAsset());
        // IERC20(lockedAsset).approve(_voteModule, amount);
        // IXRex(_xrex).approve(address(_rex33), amount);
        // IVoteModule(_voteModule).withdraw(amount);
        // IXLoan(loanContract).confirmClaimCollateral();

        // if(IVoteModule(_voteModule).balanceOf(address(this)) == 0) {
        //     address asset = address(IXLoan(loanContract)._lockedAsset());
        //     CollateralStorage.removeTotalCollateral(asset);
        // }
    }

    function xPharIncreaseLoan(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).increaseLoan(amount);
        address asset = address(IXLoan(loanContract)._vaultAsset());
        IERC20(asset).transfer(msg.sender, amount);
    }

    function xPharIncreaseCollateral(address loanContract, uint256 amount) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        _increaseCollateral(amount, address(IXLoan(loanContract)._lockedAsset()));
    }
    
    function xPharRequestLoan(uint256 collateralAmount, address loanContract, uint256 loanAmount, IXLoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));

        address asset = address(IXLoan(loanContract)._vaultAsset());
        address lockedAsset = address(IXLoan(loanContract)._lockedAsset());

        _rex33.transferFrom(msg.sender, address(this), collateralAmount);
        uint256 beginningAssetBalance = IERC20(asset).balanceOf(address(this));

        _rex33.approve(_voteModule, collateralAmount);
        _rex33.redeem(collateralAmount, address(this), address(this));
        IERC20(lockedAsset).approve(_voteModule, collateralAmount);
        IVoteModule(_voteModule).deposit(collateralAmount);
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).requestLoan(loanAmount, zeroBalanceOption, increasePercentage, preferredToken, topUp);
        IVoteModule(_voteModule).delegate(address(0));

        CollateralStorage.addTotalCollateral(lockedAsset);

        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).transfer(msg.sender, assetBalance - beginningAssetBalance);

    }

    function xPharUserVote(address loanContract, address[] calldata pools, uint256[] calldata weights) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IVoteModule(_voteModule).delegate(address(loanContract));
        IXLoan(loanContract).userVote(pools, weights);
        IVoteModule(_voteModule).delegate(address(0));
    }
    
    function xPharClaim(address loanContract, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external onlyApprovedContract(loanContract) returns (uint256) {
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        require(_accountConfigStorage.isAuthorizedCaller(msg.sender));

        // get beginning balance of preferred token and vault asset
        address vaultAsset = address(IXLoan(loanContract)._vaultAsset());
        uint256 beginningAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        uint256 beginningPreferredTokenBalance;
        uint256 beginningUnderlyingAssetBalance = _rex33.balanceOf(address(this));
        address preferredToken = IXLoan(loanContract).getPreferredToken(address(this));
        if(preferredToken != address(0)) {
            beginningPreferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
        }

        // claim the rewards
        uint256 result = IXLoan(loanContract).claim(fees, tokens, tradeData, allocations);

        // increase the collateral if necessary
        if(allocations[1] > 0) {
            // max amount we can increase is the difference between the beginning and ending locked asset balance
            uint256 rexAmount = _rex33.balanceOf(address(this)) - beginningUnderlyingAssetBalance;
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

    function xPharProcessRewards(
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
                token.approve(0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC, type(uint256).max);
            }
        }

        IXVoter(_voter).claimIncentives(address(this), gauges, tokens);
        if (tradeData.length == 0) {
            revert(); // No trade data provided, cannot proceed with claiming rewards
        }

        (bool success,) = 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC.call{value: 0}(tradeData);
        require(success);

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
            IERC20 token = IERC20(tokens[i][j]);
            uint256 tokenBalance = token.balanceOf(address(this));
            require(tokenBalance >= tokenBalances[i][j]);
            if (token.allowance(address(this), 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC) != 0) {
                    token.approve(0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC, 0);
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

    function xPharVote(address loanContract) external onlyApprovedContract(loanContract) returns (bool) {
        IVoteModule(_voteModule).delegate(address(loanContract));
        bool success = IXLoan(loanContract).vote(address(this));
        IVoteModule(_voteModule).delegate(address(0));
        return success;
    }

    function _increaseCollateral(uint256 amount, address lockedAsset) internal {
        _rex33.approve(_voteModule, amount);
        uint256 assetsReceived = _rex33.redeem(amount, address(this), address(this));
    }


    modifier onlyApprovedContract(address destination) {
        require(_accountConfigStorage.isApprovedContract(destination));
        _;
    }
    
    function xPharSetIncreasePercentage(address loanContract, uint256 increasePercentage) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setIncreasePercentage(increasePercentage);
    }

    function xPharSetPreferredToken(address loanContract, address preferredToken) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setPreferredToken(preferredToken);
    }

    function xPharSetTopUp(address loanContract, bool topUp) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setTopUp(topUp);
    }

    function xPharSetZeroBalanceOption(address loanContract, IXLoan.ZeroBalanceOption zeroBalanceOption) external onlyApprovedContract(loanContract) {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        IXLoan(loanContract).setZeroBalanceOption(zeroBalanceOption);
    }

    function migratePharaohToXPharaoh(uint256 tokenId) external {
        require(_accountConfigStorage.isApprovedContract(msg.sender));
        
        require(IERC721(_vePhar).ownerOf(tokenId) == address(this));
        IERC721(_vePhar).approve(0x2E1Ad4f8055D39442c86B1F40599293388277669, tokenId);
        PharaohMigrator(0x2E1Ad4f8055D39442c86B1F40599293388277669).migrateVe(tokenId);
        IERC20 lockedAsset = IERC20(address(IXLoan(msg.sender)._lockedAsset()));
        IERC20(lockedAsset).approve(_voteModule, type(uint256).max);
        IVoteModule(_voteModule).depositAll();
        IERC20(lockedAsset).approve(_voteModule, 0);
        if(!CollateralStorage.getTotalCollateral(address(lockedAsset))) {
            CollateralStorage.addTotalCollateral(address(lockedAsset));
        }
    }

}