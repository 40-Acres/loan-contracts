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
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
/**
 * @title RewardsProcessingFacet
 * @dev Facet that processes rewards for a portfolio account
 */
contract RewardsProcessingFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    SwapConfig public immutable _swapConfig;
    IVotingEscrow public immutable _votingEscrow;
    ILoan public immutable _loanContract;

    event ProtocolFeePaid(uint256 epoch, uint256 amount, address borrower, address asset);
    event ZeroBalanceFeePaid(uint256 epoch, uint256 amount, address borrower, address asset);
    event LenderPremiumPaid(uint256 epoch, uint256 amount, address borrower, address asset);
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address swapConfig, address votingEscrow) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(swapConfig != address(0));
        require(votingEscrow != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _swapConfig = SwapConfig(swapConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _loanContract = ILoan(_portfolioAccountConfig.getLoanContract());
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
        require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount && rewardsAmount > 0);

        // if increase percentage is set, swap the rewards amount to the asset and increase the collateral
        uint256 remaining = rewardsAmount;
        uint256 increasePercentage = getIncreasePercentage();
        if(increasePercentage > 0) {
            remaining = _increaseCollateral(tokenId, increasePercentage, asset, rewardsAmount, swapTarget, swapData);
        }

        // if have no debt, process zero balance rewards
        if(totalDebt == 0) {
            _processZeroBalanceRewards(tokenId, rewardsAmount, remaining, asset, true);
        } else {
            remaining = _processActiveLoanRewards(tokenId, rewardsAmount, remaining, asset);
            // If there are funds remaining, debt must be fully paid (remaining > 0 implies debt == 0)
            // Process zero balance rewards only when debt is fully paid and funds remain
            uint256 debtAfter = CollateralFacet(address(this)).getTotalDebt();
            if(remaining > 0) {
                require(debtAfter == 0, "If funds remain, debt must be fully paid");
                _processZeroBalanceRewards(tokenId, rewardsAmount, remaining, asset, false);
            }
        }
    }

    function _processActiveLoanRewards(uint256 tokenId, uint256 rewardsAmount, uint256 availableAmount, address asset) internal returns (uint256 remaining) {
        require(IERC20(asset).balanceOf(address(this)) >= availableAmount);
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));

        // Calculate fees based on original rewards amount
        uint256 protocolFee = _payProtocolFee(rewardsAmount, asset);
        uint256 lenderPremium = _payLenderPremium(rewardsAmount, asset);
        uint256 zeroBalanceFee = _payZeroBalanceFee(rewardsAmount, asset);
        uint256 totalFees = protocolFee + lenderPremium + zeroBalanceFee;
        
        // Ensure we have enough balance to pay fees
        require(availableAmount >= totalFees, "Insufficient balance to pay fees");
        
        // Amount available for debt payment (after fees)
        uint256 amountForDebt = availableAmount - totalFees;
        
        // Approve loan contract to transfer funds for debt payment
        IERC20(asset).approve(loanContract, amountForDebt);
        uint256 excess = CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), amountForDebt);
        // Clear approval after use
        IERC20(asset).approve(loanContract, 0);
        return excess;
    }

    function _processZeroBalanceRewards(uint256 tokenId, uint256 rewardsAmount, uint256 remaining, address asset, bool takeFees) internal {
        address rewardsToken = UserRewardsConfig.getRewardsToken();
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(rewardsToken != address(0));

        // send the zero balance fee to the treasury
        if(takeFees) {
            uint256 zeroBalanceFee = _payZeroBalanceFee(rewardsAmount, asset);
            require(remaining >= zeroBalanceFee, "Insufficient balance for zero balance fee");
            remaining -= zeroBalanceFee;
        }

        // Only process if there's remaining amount
        if(remaining == 0) {
            return;
        }

        // whatever is remaining, utlizie based on UserRewardsConfig
        address recipient = _getRecipient();
        UserRewardsConfig.ZeroBalanceRewardsOption zeroBalanceOption = UserRewardsConfig.getZeroBalanceRewardsOption();
        if(zeroBalanceOption == UserRewardsConfig.ZeroBalanceRewardsOption.PayToRecipient) {
            IERC20(asset).transfer(recipient, remaining);
        } else if(zeroBalanceOption == UserRewardsConfig.ZeroBalanceRewardsOption.InvestToVault) {
            address vault = _loanContract._vault();
            IERC20(asset).approve(vault, remaining);
            IERC4626(vault).deposit(remaining, recipient);
            // Clear approval after use
            IERC20(asset).approve(vault, 0);
        }
        // Note: If zeroBalanceOption is neither PayToRecipient nor InvestToVault, remaining funds stay in portfolio
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
        if(increasePercentage > 100) {
            increasePercentage = 100;
        }
        address lockedAsset = _votingEscrow.token();
        uint256 beginningLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        if(rewardsToken == lockedAsset) {
            // No swap needed, directly use rewards token
            uint256 amountToUse = rewardsAmount * increasePercentage / 100;
            IERC20(lockedAsset).approve(address(_votingEscrow), amountToUse);
            _votingEscrow.increaseAmount(tokenId, amountToUse);
            IERC20(lockedAsset).approve(address(_votingEscrow), 0);
            CollateralManager.updateLockedCollateral(tokenId, address(_votingEscrow));
            return rewardsAmount - amountToUse;
        }

        require(swapTarget != address(0), "Swap target must be provided");
        // swap the rewards amount to the locked asset
        uint256 amountToSwap = rewardsAmount * increasePercentage / 100;
        IERC20(rewardsToken).approve(swapTarget, amountToSwap);
        SwapMod.swap(address(_swapConfig), swapTarget, swapData, rewardsToken, amountToSwap, lockedAsset, 0);
        // Clear approval after swap
        IERC20(rewardsToken).approve(swapTarget, 0);
        remaining = rewardsAmount - amountToSwap;

        uint256 endingLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        uint256 increaseAmount = endingLockedAssetBalance - beginningLockedAssetBalance;
        // increase the collateral
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        _votingEscrow.increaseAmount(tokenId, increaseAmount);
        // Clear approval after use
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        CollateralManager.updateLockedCollateral(tokenId, address(_votingEscrow));

        return remaining;
    }

    function _payZeroBalanceFee(uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 zeroBalanceFee = (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee()) / 10000;
        IERC20(asset).transfer(_portfolioAccountConfig.getLoanContract(), zeroBalanceFee);
        emit ZeroBalanceFeePaid(_currentEpochStart(), zeroBalanceFee, _portfolioFactory.ownerOf(address(this)), address(asset));
        return zeroBalanceFee;
    }

    function _payLenderPremium(uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 lenderPremium = (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getLenderPremium()) / 10000;
        IERC20(asset).transfer(_portfolioAccountConfig.owner(), lenderPremium);
        emit LenderPremiumPaid(_currentEpochStart(), lenderPremium, _portfolioFactory.ownerOf(address(this)), address(asset));
        return lenderPremium;
    }

    function _payProtocolFee(uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 protocolFee = (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getTreasuryFee()) / 10000;
        IERC20(asset).transfer(_portfolioAccountConfig.owner(), protocolFee);
        emit ProtocolFeePaid(_currentEpochStart(), protocolFee, _portfolioFactory.ownerOf(address(this)), address(asset));
        return protocolFee;
    }

    function _getRecipient() internal view returns (address) {
        address recipient = UserRewardsConfig.getRecipient();
        if(recipient == address(0)) {
            recipient = _portfolioFactory.ownerOf(address(this));
        }
        return recipient;
    }
    
    function _currentEpochStart() internal view returns (uint256) {
        return ProtocolTimeLibrary.epochStart(block.timestamp);
    }
}

