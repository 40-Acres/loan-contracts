// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";
import {UserRewardsConfig} from "./UserRewardsConfig.sol";
import {SwapMod} from "../swap/SwapMod.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {CollateralFacet} from "../collateral/CollateralFacet.sol";
/**
 * @title RewardsProcessingFacet
 * @dev Facet that processes rewards for a portfolio account
 */
contract RewardsProcessingFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    SwapConfig public immutable _swapConfig;
    IVotingEscrow public immutable _votingEscrow;
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address swapConfig, address votingEscrow) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(swapConfig != address(0));
        require(votingEscrow != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _swapConfig = SwapConfig(swapConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
    }

    function processRewards(uint256 tokenId, uint256 rewardsAmount, address asset, address swapTarget, bytes memory swapData) external onlyAuthorizedCaller(_portfolioFactory) {
        uint256 totalDebt = CollateralFacet(address(this)).getTotalDebt();
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));
        
        // Get vault asset from loan contract if we have debt, otherwise use rewards token
        address vaultAsset = totalDebt > 0 ? ILoan(loanContract)._asset() : UserRewardsConfig.getRewardsToken();
        if (asset == address(0)) {
            asset = vaultAsset;
        }
        // Validate rewards token when processing zero balance rewards
        if (totalDebt == 0) {
            require(UserRewardsConfig.getRewardsToken() != address(0), "Rewards token must be set");
        }
        require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount);

        // if increase percentage is set, swap the rewards amount to the asset and increase the collateral
        uint256 remaining = rewardsAmount;
        uint256 increasePercentage = getIncreasePercentage();
        if(increasePercentage > 0) {
            remaining = _increaseCollateral(tokenId, increasePercentage, asset, rewardsAmount, swapTarget, swapData);
        }

        // if have no debt, process zero balance rewards
        if(totalDebt == 0) {
            _processZeroBalanceRewards(tokenId, rewardsAmount, remaining, asset, swapTarget, swapData);
        } else {
            IERC20(asset).approve(loanContract, rewardsAmount);
            remaining = _processActiveLoanRewards(tokenId, rewardsAmount, remaining, asset, swapTarget, swapData);
            if(remaining > 0) {
                _processZeroBalanceRewards(tokenId, rewardsAmount, remaining, asset, swapTarget, swapData);
            }
        }
    }

    function _processActiveLoanRewards(uint256 tokenId, uint256 rewardsAmount, address asset, address swapTarget, bytes memory swapData) internal returns (uint256 remaining) {
        require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount);
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));
        IERC20(asset).approve(loanContract, rewardsAmount);
        remaining = ILoan(loanContract).handleActiveLoanPortfolioAccount(tokenId, rewardsAmount);
        return remaining;
    }

    function _processZeroBalanceRewards(uint256 tokenId, uint256 rewardsAmount, address asset, address swapTarget, bytes memory swapData) internal {
        address rewardsToken = UserRewardsConfig.getRewardsToken();
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(rewardsToken != address(0));

        // send the zero balance fee to the treasury
        uint256 zeroBalanceFee = (rewardsAmount * getZeroBalanceFee()) / 10000;
        IERC20(asset).transfer(owner(), zeroBalanceFee);
        emit ProtocolFeePaid(currentEpochStart(), zeroBalanceFee, loan.borrower, tokenId, address(asset));
        rewardsAmount -= zeroBalanceFee;

        uint256 increasePercentage = getIncreasePercentage();
        rewardsAmount = _increaseCollateral(tokenId, increasePercentage, asset, rewardsAmount, swapTarget, swapData);

        // whatever is remaining, utlizie based on UserRewardsConfig
        UserRewardsConfig.ZeroBalanceRewardsOption zeroBalanceOption = UserRewardsConfig.getZeroBalanceRewardsOption();
        if(zeroBalanceOption == UserRewardsConfig.ZeroBalanceRewardsOption.PayToRecipient) {
            address recipient = UserRewardsConfig.getRecipient();
            IERC20(asset).transfer(recipient, rewardsAmount);
        } 
        if(zeroBalanceOption == UserRewardsConfig.ZeroBalanceRewardsOption.InvestToVault) {
            address vault = ILoan(loanContract)._vault();
            address recipient = UserRewardsConfig.getRecipient();
            IERC20(asset).approve(vault, remaining);
            IERC4626(vault).deposit(rewardsAmount, recipient);
        }
    }

    function setActiveRewardsOption(UserRewardsConfig.ActiveRewardsOption activeRewardsOption) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setActiveRewardsOption(activeRewardsOption);
    }

    function setZeroBalanceRewardsOption(UserRewardsConfig.ZeroBalanceRewardsOption zeroBalanceRewardsOption) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setZeroBalanceRewardsOption(zeroBalanceRewardsOption);
    }
    
    function getActiveRewardsOption() public view returns (UserRewardsConfig.ActiveRewardsOption) {
        return UserRewardsConfig.getActiveRewardsOption();
    }

    function getZeroBalanceRewardsOption() public view returns (UserRewardsConfig.ZeroBalanceRewardsOption) {
        return UserRewardsConfig.getZeroBalanceRewardsOption();
    }

    function setIncreasePercentage(uint256 increasePercentage) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setIncreasePercentage(increasePercentage);
    }

    function getIncreasePercentage() public view returns (uint256) {
        uint256 totalDebt = CollateralFacet(address(this)).getTotalDebt();
        uint256 rewardsPercentage = UserRewardsConfig.getIncreasePercentage();
        if(totalDebt > 0 && rewardsPercentage > 25) {
            return 25;
        } else {
            return rewardsPercentage;
        }
    }

    function setRewardsToken(address rewardsToken) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRewardsToken(rewardsToken);
    }

    function setRecipient(address recipient) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRecipient(recipient);
    }

    function _increaseCollateral(uint256 tokenId, uint256 increasePercentage, address rewardsToken, uint256 rewardsAmount, address swapTarget, bytes memory swapData) internal returns (uint256 remaining) {
        address lockedAsset = _votingEscrow.token();
        // swap the rewards amount to the asset
        uint256 beginningLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));

        uint256 amountToSwap = rewardsAmount * increasePercentage / 100;
        IERC20(rewardsToken).approve(swapTarget, amountToSwap);
        SwapMod.swap(address(_swapConfig), swapTarget, swapData, rewardsToken, amountToSwap, lockedAsset, 0);

        uint256 endingLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        uint256 increaseAmount = endingLockedAssetBalance - beginningLockedAssetBalance;
        // increase the collateral
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        _votingEscrow.increaseAmount(tokenId, increaseAmount);
        remaining = rewardsAmount - amountToSwap;
        CollateralManager.updateLockedColleratal(tokenId, address(_votingEscrow));

        return remaining;
    }

    function _payZeroBalanceFee(uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 zeroBalanceFee = (rewardsAmount * _portfolioAccountConfig.getZeroBalanceFee()) / 10000;
        IERC20(asset).transfer(owner(), zeroBalanceFee);
        emit ProtocolFeePaid(currentEpochStart(), zeroBalanceFee, loan.borrower, tokenId, address(asset));
        return zeroBalanceFee;
    }

    function _payLenderPremium(uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 lenderPremium = (rewardsAmount * _portfolioAccountConfig.getLenderPremium()) / 10000;
        IERC20(asset).transfer(owner(), lenderPremium);
        emit ProtocolFeePaid(currentEpochStart(), lenderPremium, loan.borrower, tokenId, address(asset));
        return lenderPremium;
    }

    function payProtocolFee(uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 protocolFee = (rewardsAmount * _portfolioAccountConfig.getProtocolFee()) / 10000;
        IERC20(asset).transfer(owner(), protocolFee);
        emit ProtocolFeePaid(currentEpochStart(), protocolFee, loan.borrower, tokenId, address(asset));
        return protocolFee;
    }
    
}

