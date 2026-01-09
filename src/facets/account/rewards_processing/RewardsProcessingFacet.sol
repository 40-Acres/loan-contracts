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
    IERC4626 public immutable _vault;


    event GasReclamationPaid(uint256 epoch, uint256 amount, address user, address asset);
    event ProtocolFeePaid(uint256 epoch, uint256 amount, address user, address asset);
    event ZeroBalanceFeePaid(uint256 epoch, uint256 amount, address user, address asset);
    event LenderPremiumPaid(uint256 epoch, uint256 amount, address user, address asset);
    event RewardsProcessed(uint256 epoch, uint256 rewardsAmount, address user, address asset);
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address swapConfig, address votingEscrow, address vault) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(swapConfig != address(0));
        require(votingEscrow != address(0));
        // vault can be zero address if there is no vault (no lending)
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _swapConfig = SwapConfig(swapConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _vault = IERC4626(vault);
    }

    function processRewards(uint256 tokenId, uint256 rewardsAmount, address swapTarget, uint256 minimumOutputAmount, bytes memory swapData, uint256 gasReclamation) external onlyAuthorizedCaller(_portfolioFactory) {
        address asset = getRewardsToken();
        emit RewardsProcessed(_currentEpochStart(), rewardsAmount, _portfolioFactory.ownerOf(address(this)), address(asset));
        require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount && rewardsAmount > 0);

        // if increase percentage is set, swap the rewards amount to the asset and increase the collateral
        uint256 remaining = rewardsAmount;

        // send gas reclamation to the tx.origin
        if(gasReclamation > 0) {
            // amount of gas is capped at 5% of the rewards amount
            uint256 gasReclamationCap = rewardsAmount * 5 / 100;
            if(gasReclamation > gasReclamationCap) {
                gasReclamation = gasReclamationCap;
            }
            emit GasReclamationPaid(_currentEpochStart(), gasReclamation, _portfolioFactory.ownerOf(address(this)), address(asset));
            IERC20(asset).transfer(tx.origin, gasReclamation);
            remaining -= gasReclamation;
        }

        UserRewardsConfig.RewardsOption rewardsOption = getRewardsOption();
        uint256 rewardsOptionPercentage = getRewardsOptionPercentage();
        if(rewardsOptionPercentage > 0) {
            if(rewardsOption == UserRewardsConfig.RewardsOption.IncreaseCollateral) {
                remaining -= _increaseCollateral(tokenId, rewardsOptionPercentage, asset, rewardsAmount, swapTarget, minimumOutputAmount, swapData);
            }
            if(rewardsOption == UserRewardsConfig.RewardsOption.InvestToVault) {
                remaining -= _investToVault(rewardsAmount, rewardsOptionPercentage, asset, swapTarget, minimumOutputAmount, swapData);
            }
            if(rewardsOption == UserRewardsConfig.RewardsOption.PayToRecipient) {
                remaining -= _payToRecipient(rewardsAmount, rewardsOptionPercentage, asset);
            }
        }

        // if have no debt, process zero balance rewards
        uint256 totalDebt = CollateralFacet(address(this)).getTotalDebt();
        if(totalDebt == 0) {
            _processZeroBalanceRewards(rewardsAmount, remaining, asset, true);
        } else {
            remaining = _processActiveLoanRewards(rewardsAmount, remaining, asset);
            // If there are funds remaining, debt must be fully paid (remaining > 0 implies debt == 0)
            // Deposit to vault if any funds remain, this ensure if any owners are blacklisted the lender does not lose funds
            if(remaining > 0) {
                // if any funds remain, deposit to vault
                IERC20(asset).approve(address(_vault), remaining);
                _vault.deposit(remaining, _portfolioFactory.ownerOf(address(this)));
                // Clear approval after use
                IERC20(asset).approve(address(_vault), 0);
            }
        }
    }


    /**
        * @dev Returns the rewards token to use for the rewards processing.
        * @return The rewards token to use for the rewards processing.
        * If there is debt, the vault asset is used.
        * If there is no debt, the rewards token is used if set, otherwise the vault asset is used.
     */
    function getRewardsToken() public view returns (address) {        
        uint256 totalDebt = CollateralFacet(address(this)).getTotalDebt();
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));
        
        if(totalDebt > 0) {
            return _vault.asset();
        }

        return UserRewardsConfig.getRewardsToken() != address(0) ? UserRewardsConfig.getRewardsToken() : _vault.asset();
    }

    function _processActiveLoanRewards(uint256 rewardsAmount, uint256 availableAmount, address asset) internal returns (uint256 remaining) {
        require(IERC20(asset).balanceOf(address(this)) >= availableAmount);
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));

        // Calculate fees based on original rewards amount
        uint256 protocolFee = _payProtocolFee(rewardsAmount, asset);
        uint256 lenderPremium = _payLenderPremium(rewardsAmount, asset);
        uint256 totalFees = protocolFee + lenderPremium;
        
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

    function _processZeroBalanceRewards(uint256 rewardsAmount, uint256 remaining, address asset, bool takeFees) internal {
        address asset = getRewardsToken();

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

        // whatever is remaining, send to recipient
        address recipient = _getRecipient();
        require(recipient != address(0));
        IERC20(asset).transfer(recipient, remaining);
    }

    function setRewardsOption(UserRewardsConfig.RewardsOption rewardsOption) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRewardsOption(rewardsOption);
    }

    function getRewardsOption() public view returns (UserRewardsConfig.RewardsOption) {
        return (UserRewardsConfig.getRewardsOption());
    }

    function getRewardsOptionPercentage() public view returns (uint256) {
        uint256 totalDebt = CollateralFacet(address(this)).getTotalDebt();
        uint256 rewardsPercentage = UserRewardsConfig.getRewardsOptionPercentage();
        if(totalDebt > 0 && rewardsPercentage > 25) {
            return 25;
        } 
        // if no balance the rewards percentage is net fees
        uint256 zeroBalanceFeePercentage = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee() / 100;
        if(rewardsPercentage > 100 - zeroBalanceFeePercentage) {
            return 100 - zeroBalanceFeePercentage;
        }
        return rewardsPercentage;
    }

    function setRewardsToken(address rewardsToken) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRewardsToken(rewardsToken);
    }

    function setRewardsOptionPercentage(uint256 rewardsOptionPercentage) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRewardsOptionPercentage(rewardsOptionPercentage);
    }

    function setRecipient(address recipient) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRecipient(recipient);
    }

    function _investToVault(uint256 rewardsAmount, uint256 percentage, address asset, address swapTarget, uint256 minimumOutputAmount, bytes memory swapData) internal returns (uint256 amountUsed) {
        address vaultAsset = _vault.asset();
        uint256 rewardsAmountUsed = rewardsAmount * percentage / 100;
        uint256 actualAmountToInvest = rewardsAmountUsed;
        
        if(asset != vaultAsset) {
            // swap the asset to the vault asset
            IERC20(asset).approve(swapTarget, rewardsAmountUsed);
            actualAmountToInvest = SwapMod.swap(address(_swapConfig), swapTarget, swapData, asset, rewardsAmountUsed, vaultAsset, minimumOutputAmount);
            // Clear approval after swap
            IERC20(asset).approve(swapTarget, 0);
        }

        // Get the actual vault asset balance (after swap if applicable)
        uint256 vaultAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        // Use the minimum of calculated amount and actual balance to avoid over-depositing
        uint256 amountToDeposit = vaultAssetBalance < actualAmountToInvest ? vaultAssetBalance : actualAmountToInvest;
        
        // deposit the asset to the vault
        IERC20(vaultAsset).approve(address(_vault), amountToDeposit);
        address recipient = _portfolioFactory.ownerOf(address(this));
        _vault.deposit(amountToDeposit, recipient);
        // Clear approval after use
        IERC20(vaultAsset).approve(address(_vault), 0);
        
        // if the asset is the vault asset, return the amount to deposit, otherwise return the rewards amount used
        return asset == vaultAsset ? amountToDeposit : rewardsAmountUsed;
    }


    function _payToRecipient(uint256 rewardsAmount, uint256 percentage, address asset) internal returns (uint256 amountPaid) {
        // if fail to transfer, keep amountPaid to 0 so it will process to remaining funds as normal
        uint256 amountToPay = rewardsAmount * percentage / 100;
        address recipient = _getRecipient();
        require(recipient != address(0));
        try IERC20(asset).transfer(recipient, amountToPay) returns (bool success) {
            if(!success) {
                return 0;
            }
        } catch {
            return 0;
        }
        return amountToPay;
    }

    function _increaseCollateral(uint256 tokenId, uint256 increasePercentage, address rewardsToken, uint256 rewardsAmount, address swapTarget, uint256 minimumOutputAmount, bytes memory swapData) internal returns (uint256 amountUsed) {
        address lockedAsset = _votingEscrow.token();
        uint256 beginningLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        if(rewardsToken == lockedAsset) {
            // No swap needed, directly use rewards token
            uint256 amountToUse = rewardsAmount * increasePercentage / 100;
            IERC20(lockedAsset).approve(address(_votingEscrow), amountToUse);
            _votingEscrow.increaseAmount(tokenId, amountToUse);
            IERC20(lockedAsset).approve(address(_votingEscrow), 0);
            CollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
            return rewardsAmount - amountToUse;
        }

        require(swapTarget != address(0), "Swap target must be provided");
        // swap the rewards amount to the locked asset
        uint256 amountToSwap = rewardsAmount * increasePercentage / 100;
        IERC20(rewardsToken).approve(swapTarget, amountToSwap);
        SwapMod.swap(address(_swapConfig), swapTarget, swapData, rewardsToken, amountToSwap, lockedAsset, minimumOutputAmount);
        // Clear approval after swap
        IERC20(rewardsToken).approve(swapTarget, 0);

        uint256 endingLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        uint256 increaseAmount = endingLockedAssetBalance - beginningLockedAssetBalance;
        // increase the collateral
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        _votingEscrow.increaseAmount(tokenId, increaseAmount);
        // Clear approval after use
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        CollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));

        return amountToSwap;
    }

    function swapToRewardsToken(address swapConfig, address swapTarget, bytes memory swapData, address inputToken, uint256 inputAmount, uint256 minimumOutputAmount) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 amount) {
        address rewardsToken = getRewardsToken();
        require(inputToken != rewardsToken, "Input token cannot be rewards token");
        require(swapTarget == rewardsToken, "Output token must be rewards token");
        return SwapMod.swap(swapConfig, swapTarget, swapData, inputToken, inputAmount, rewardsToken, minimumOutputAmount);
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

