// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";
import {UserRewardsConfig} from "./UserRewardsConfig.sol";
import {SwapMod} from "../swap/SwapMod.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {CollateralFacet} from "../collateral/CollateralFacet.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
import {IPortfolioManager} from "../../../accounts/IPortfolioManager.sol";

interface ILendingFacet {
    function pay(uint256 amount) external returns (uint256 excess);
}

/**
 * @title RewardsProcessingFacet
 * @dev Facet that processes rewards for a portfolio account
 */
contract RewardsProcessingFacet is AccessControl {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    SwapConfig public immutable _swapConfig;
    IVotingEscrow public immutable _votingEscrow;
    IERC4626 public immutable _vault;


    event GasReclamationPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ProtocolFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event ZeroBalanceFeePaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event LenderPremiumPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event RewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 rewardsAmount, address user, address asset);
    event LoanPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset);
    event DebtPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address recipient, address asset);
    event PaidToRecipient(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);
    event InvestedToVault(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event ZeroBalanceRewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 remainingAmount, address indexed recipient, address asset, address indexed owner);
    
    event RewardsOptionSet(UserRewardsConfig.RewardsOption rewardsOption, address indexed owner);
    event RewardsTokenSet(address rewardsToken, address indexed owner);
    event RewardsOptionPercentageSet(uint256 percentage, address indexed owner);
    event RecipientSet(address recipient, address indexed owner);
    event CollateralIncreased(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);
    event IncreaseCollateralPercentageSet(uint256 percentage, address indexed owner);
    event FinalRewardsOptionSet(UserRewardsConfig.RewardsOption finalRewardsOption, address indexed owner);
    
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

    /**
    @dev Main entry point for processing rewards. This function will be called by the rewards distributor contract when distributing rewards to this portfolio account.
    The processing flow is as follows:
    1. Pay protocol fee and lender premium (
    2. Handle gas reclamation
    3. Process rewards option
    4. Finalize rewards
     */
    function processRewards(uint256 tokenId, uint256 rewardsAmount, SwapMod.RouteParams[3] memory swapParams, uint256 gasReclamation) external onlyAuthorizedCaller(_portfolioFactory) {
        address asset = getRewardsToken();
        emit RewardsProcessed(_currentEpochStart(), tokenId, rewardsAmount, _portfolioFactory.ownerOf(address(this)), asset);
        require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount && rewardsAmount > 0);

        // 1. Fees first — computed on original rewardsAmount
        uint256 remaining = rewardsAmount;
        if (CollateralFacet(address(this)).getTotalDebt() > 0) {
            remaining -= _payProtocolFee(tokenId, rewardsAmount, asset);
            remaining -= _payLenderPremium(tokenId, rewardsAmount, asset);
        } else {
            remaining -= _payZeroBalanceFee(tokenId, rewardsAmount, asset);
        }

        // Post-fees amount is the base for percentage calculations
        // so 50/50 truly means 50/50 of what's distributable
        uint256 postFeesAmount = remaining;

        // 2. Gas reclamation — cap computed on original rewardsAmount
        remaining = _handleGasReclamation(tokenId, rewardsAmount, asset, gasReclamation, remaining);

        // 3. Rewards option — percentages on postFeesAmount, deducted from remaining
        remaining = _processRewardsOption(tokenId, postFeesAmount, remaining, asset, swapParams[0]);

        // 4. Debt payment or send to recipient (fees already deducted)
        _finalizeRewards(tokenId, postFeesAmount, remaining, asset, swapParams);
    }

    function _handleGasReclamation(uint256 tokenId, uint256 rewardsAmount, address asset, uint256 gasReclamation, uint256 remaining) internal returns (uint256) {
        if(gasReclamation > 0) {
            // amount of gas is capped at 5% of the rewards amount
            uint256 gasReclamationCap = rewardsAmount * 5 / 100;
            if(gasReclamation > gasReclamationCap) {
                gasReclamation = gasReclamationCap;
            }
            emit GasReclamationPaid(_currentEpochStart(), tokenId, gasReclamation, _portfolioFactory.ownerOf(address(this)), asset);
            IERC20(asset).safeTransfer(msg.sender, gasReclamation);
            remaining -= gasReclamation;
        }
        return remaining;
    }

    function _processRewardsOption(uint256 tokenId, uint256 postFeesAmount, uint256 remaining, address asset, SwapMod.RouteParams memory swapParams) internal returns (uint256) {
        uint256 rewardsOptionPercentage = getRewardsOptionPercentage();
        if(rewardsOptionPercentage > 0) {
            uint256 optionAmount = postFeesAmount * rewardsOptionPercentage / 100;
            // Cap at remaining to prevent underflow when gas + option > postFeesAmount
            if(optionAmount > remaining) {
                optionAmount = remaining;
            }
            UserRewardsConfig.RewardsOption rewardsOption = getRewardsOption();
            uint256 used;
            if(rewardsOption == UserRewardsConfig.RewardsOption.IncreaseCollateral) {
                used = _increaseCollateral(tokenId, asset, optionAmount, swapParams);
            } else if(rewardsOption == UserRewardsConfig.RewardsOption.InvestToVault) {
                used = _investToVault(tokenId, optionAmount, asset, swapParams);
            } else if(rewardsOption == UserRewardsConfig.RewardsOption.PayToRecipient) {
                used = _payToRecipient(tokenId, optionAmount, asset);
            } else if(rewardsOption == UserRewardsConfig.RewardsOption.PayDebt) {
                used = _payDebt(tokenId, optionAmount, asset);
            }
            remaining -= used;
        }
        return remaining;
    }

    function _finalizeRewards(uint256 tokenId, uint256 postFeesAmount, uint256 remaining, address asset, SwapMod.RouteParams[3] memory swapParams) internal {
        // Fees already deducted
        if(CollateralFacet(address(this)).getTotalDebt() == 0) {
            remaining -= _processIncreaseCollateralRewards(tokenId, postFeesAmount, remaining, asset, swapParams[1]);
            _processZeroBalanceRewards(tokenId, remaining, asset, swapParams[2]);
        } else {
            remaining = _processActiveLoanRewards(tokenId, remaining, asset);
            if(remaining > 0) {
                _depositRemainingToVault(remaining, asset);
            }
        }
    }

    function _depositRemainingToVault(uint256 amount, address asset) internal {
        address vaultAddress = address(_vault);
        IERC20(asset).approve(vaultAddress, amount);
        _vault.deposit(amount, _portfolioFactory.ownerOf(address(this)));
        // Clear approval after use
        IERC20(asset).approve(vaultAddress, 0);
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
        address vaultAsset = _vault.asset();
        
        if(totalDebt > 0) {
            return vaultAsset;
        }
        address rewardsToken = UserRewardsConfig.getRewardsToken();
        return rewardsToken != address(0) ? rewardsToken : vaultAsset;
    }

    function _processActiveLoanRewards(uint256 tokenId, uint256 availableAmount, address asset) internal virtual returns (uint256 remaining) {
        require(IERC20(asset).balanceOf(address(this)) >= availableAmount);
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));

        // Fees already deducted in _deductFees — all availableAmount goes to debt
        uint256 excess = CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), availableAmount);
        emit LoanPaid(_currentEpochStart(), tokenId, availableAmount, _portfolioFactory.ownerOf(address(this)), address(asset));

        return excess;
    }

    function _processIncreaseCollateralRewards(uint256 tokenId, uint256 postFeesAmount, uint256 remaining, address asset, SwapMod.RouteParams memory swapParams) internal returns (uint256 amountUsed) {
        uint256 increaseCollateralPercentage = getIncreaseCollateralPercentage();
        if(increaseCollateralPercentage == 0 || remaining == 0) {
            return 0;
        }
        uint256 collateralAmount = postFeesAmount * increaseCollateralPercentage / 100;
        if(collateralAmount > remaining) {
            collateralAmount = remaining;
        }
        return _increaseCollateral(tokenId, asset, collateralAmount, swapParams);
    }

    function _processZeroBalanceRewards(uint256 tokenId, uint256 remaining, address asset, SwapMod.RouteParams memory swapParams) internal {
        if(remaining == 0) {
            return;
        }

        UserRewardsConfig.RewardsOption finalOption = getFinalRewardsOption();
        uint256 used;
        if(finalOption == UserRewardsConfig.RewardsOption.IncreaseCollateral) {
            used = _increaseCollateral(tokenId, asset, remaining, swapParams);
        } else if(finalOption == UserRewardsConfig.RewardsOption.InvestToVault) {
            used = _investToVault(tokenId, remaining, asset, swapParams);
        } else if(finalOption == UserRewardsConfig.RewardsOption.PayDebt) {
            used = _payDebt(tokenId, remaining, asset);
        } else if(finalOption == UserRewardsConfig.RewardsOption.PayToRecipient) {
            used = _payToRecipient(tokenId, remaining, asset);
        }

        // Whatever wasn't used by the option goes to recipient
        uint256 toRecipient = remaining - used;
        if(toRecipient > 0) {
            address recipient = _getRecipient();
            IERC20(asset).safeTransfer(recipient, toRecipient);
        }
        emit ZeroBalanceRewardsProcessed(_currentEpochStart(), tokenId, remaining, _getRecipient(), asset, _portfolioFactory.ownerOf(address(this)));
    }

    function setRewardsOption(UserRewardsConfig.RewardsOption rewardsOption) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        if(rewardsOption != UserRewardsConfig.RewardsOption.PayBalance) {
            require(rewardsOption != UserRewardsConfig.getFinalRewardsOption(), "Rewards option must differ from final rewards option");
        }
        UserRewardsConfig.setRewardsOption(rewardsOption);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit RewardsOptionSet(rewardsOption, owner);
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
        return rewardsPercentage;
    }

    function setRewardsToken(address rewardsToken) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRewardsToken(rewardsToken);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit RewardsTokenSet(rewardsToken, owner);
    }

    function setRewardsOptionPercentage(uint256 rewardsOptionPercentage) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(rewardsOptionPercentage + UserRewardsConfig.getIncreaseCollateralPercentage() <= 100, "Cumulative percentages exceed 100%");
        UserRewardsConfig.setRewardsOptionPercentage(rewardsOptionPercentage);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit RewardsOptionPercentageSet(rewardsOptionPercentage, owner);
    }

    function setRecipient(address recipient) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRecipient(recipient);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit RecipientSet(recipient, owner);
    }

    function setIncreaseCollateralPercentage(uint256 percentage) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(percentage + UserRewardsConfig.getRewardsOptionPercentage() <= 100, "Cumulative percentages exceed 100%");
        UserRewardsConfig.setIncreaseCollateralPercentage(percentage);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit IncreaseCollateralPercentageSet(percentage, owner);
    }

    function getIncreaseCollateralPercentage() public view returns (uint256) {
        return UserRewardsConfig.getIncreaseCollateralPercentage();
    }

    function setFinalRewardsOption(UserRewardsConfig.RewardsOption finalRewardsOption) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        if(finalRewardsOption != UserRewardsConfig.RewardsOption.PayBalance) {
            require(finalRewardsOption != UserRewardsConfig.getRewardsOption(), "Final rewards option must differ from rewards option");
        }
        UserRewardsConfig.setFinalRewardsOption(finalRewardsOption);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit FinalRewardsOptionSet(finalRewardsOption, owner);
    }

    function getFinalRewardsOption() public view returns (UserRewardsConfig.RewardsOption) {
        return UserRewardsConfig.getFinalRewardsOption();
    }

    function _investToVault(uint256 tokenId, uint256 optionAmount, address asset, SwapMod.RouteParams memory swapParams) internal returns (uint256 amountUsed) {
        IERC4626 vault = IERC4626(UserRewardsConfig.getVaultForInvesting());
        if(address(vault) == address(0)) {
            vault = _vault;
        }
        address vaultAsset = vault.asset();
        uint256 amountToDeposit;

        uint256 actualAmountToInvest = optionAmount;
        if(asset != vaultAsset) {
            actualAmountToInvest = SwapMod.swap(SwapMod.RouteParams({
                swapConfig: address(_swapConfig),
                swapTarget: swapParams.swapTarget,
                swapData: swapParams.swapData,
                inputToken: asset,
                inputAmount: optionAmount,
                outputToken: vaultAsset,
                minimumOutputAmount: swapParams.minimumOutputAmount
            }));
        }
        uint256 vaultAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        amountToDeposit = vaultAssetBalance < actualAmountToInvest ? vaultAssetBalance : actualAmountToInvest;

        IERC20(vaultAsset).approve(address(vault), amountToDeposit);
        address recipient = _portfolioFactory.ownerOf(address(this));
        vault.deposit(amountToDeposit, recipient);
        IERC20(vaultAsset).approve(address(vault), 0);

        emit InvestedToVault(_currentEpochStart(), tokenId, amountToDeposit, asset, recipient);
        return asset == vaultAsset ? amountToDeposit : optionAmount;
    }

    function _payDebt(uint256 tokenId, uint256 amountToPay, address asset) internal returns (uint256 amountPaid) {
        address recipient = _getRecipient();

        // ensure the recipient is a portfolio account owned by the same user
        IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
        if (!portfolioManager.isPortfolioRegistered(recipient)) {
            return 0;
        }
        address recipientFactory = portfolioManager.getFactoryForPortfolio(recipient);
        address recipientOwner = PortfolioFactory(recipientFactory).ownerOf(recipient);
        address thisOwner = _portfolioFactory.ownerOf(address(this));
        if (recipientOwner != thisOwner) {
            return 0;
        }

        // approve the portfolio to pull the tokens
        IERC20(asset).approve(recipient, amountToPay);

        // call pay on the portfolio's LendingFacet
        try ILendingFacet(recipient).pay(amountToPay) returns (uint256 excess) {
            // Calculate actual amount paid (amountToPay - excess)
            amountPaid = amountToPay - excess;
            emit DebtPaid(_currentEpochStart(), tokenId, amountPaid, recipient, asset);
        } catch {
            amountPaid = 0;
        }
        IERC20(asset).approve(recipient, 0);
        return amountPaid;
    }


    function _payToRecipient(uint256 tokenId, uint256 amountToPay, address asset) internal returns (uint256 amountPaid) {
        // if fail to transfer, keep amountPaid to 0 so it will process to remaining funds as normal
        address recipient = _getRecipient();
        bool success = IERC20(asset).trySafeTransfer(recipient, amountToPay);
        if(!success) {
            return 0;
        }
        emit PaidToRecipient(_currentEpochStart(), tokenId, amountToPay, recipient, asset, _portfolioFactory.ownerOf(address(this)));
        return amountToPay;
    }

    function _increaseCollateral(uint256 tokenId, address rewardsToken, uint256 optionAmount, SwapMod.RouteParams memory swapParams) internal returns (uint256 amountUsed) {
        address lockedAsset = _votingEscrow.token();
        uint256 beginningLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        if(rewardsToken == lockedAsset) {
            // No swap needed, directly use rewards token
            _increaseLock(tokenId, optionAmount, lockedAsset);
            return optionAmount;
        }

        require(swapParams.swapTarget != address(0), "Swap target must be provided");
        // swap the rewards amount to the locked asset
        SwapMod.swap(SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: swapParams.swapTarget,
            swapData: swapParams.swapData,
            inputToken: rewardsToken,
            inputAmount: optionAmount,
            outputToken: lockedAsset,
            minimumOutputAmount: swapParams.minimumOutputAmount
        }));

        uint256 endingLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        uint256 increaseAmount = endingLockedAssetBalance - beginningLockedAssetBalance;
        // increase the collateral
        _increaseLock(tokenId, increaseAmount, lockedAsset);
        return optionAmount;
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) virtual internal {
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        IVotingEscrow(address(_votingEscrow)).increaseAmount(tokenId, increaseAmount);
        // Clear approval after use
        IERC20(lockedAsset).approve(address(_votingEscrow), 0);
        CollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
        emit CollateralIncreased(_currentEpochStart(), tokenId, increaseAmount, _portfolioFactory.ownerOf(address(this)));
    }

    function swapToRewardsToken(SwapMod.RouteParams memory params) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 amount) {
        if(params.inputToken == CollateralFacet(address(this)).getCollateralToken()) {
            revert("Input token cannot be collateral token");
        }
        address rewardsToken = getRewardsToken();
        require(params.inputToken != rewardsToken, "Input token cannot be rewards token");
        return SwapMod.swap(SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: params.swapTarget,
            swapData: params.swapData,
            inputToken: params.inputToken,
            inputAmount: params.inputAmount,
            outputToken: rewardsToken,
            minimumOutputAmount: params.minimumOutputAmount
        }));
    }

    function _payZeroBalanceFee(uint256 tokenId, uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 zeroBalanceFee = (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee()) / 10000;
        IERC20(asset).safeTransfer(_portfolioAccountConfig.getLoanContract(), zeroBalanceFee);
        emit ZeroBalanceFeePaid(_currentEpochStart(), tokenId, zeroBalanceFee, _portfolioFactory.ownerOf(address(this)), address(asset));
        return zeroBalanceFee;
    }
    
    
    function swapToRewardsTokenMultiple(SwapMod.RouteParams[] memory params) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 amount) {
        address rewardsToken = getRewardsToken();
        for(uint256 i = 0; i < params.length; i++) {
            if(params[i].inputToken == CollateralFacet(address(this)).getCollateralToken()) {
                revert("Input token cannot be collateral token");
            }
            require(params[i].inputToken != rewardsToken, "Input token cannot be rewards token");
            try SwapMod.swap(SwapMod.RouteParams({
                swapConfig: address(_swapConfig),
                swapTarget: params[i].swapTarget,
                swapData: params[i].swapData,
                inputToken: params[i].inputToken,
                inputAmount: params[i].inputAmount,
                outputToken: rewardsToken,
                minimumOutputAmount: params[i].minimumOutputAmount
            })) returns (uint256 swappedAmount) {
                amount += swappedAmount;
            } catch {
                continue;
            }
        }
        return amount;
    }

    function _payLenderPremium(uint256 tokenId, uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 lenderPremium = (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getLenderPremium()) / 10000;

        IERC20(asset).safeTransfer(_portfolioAccountConfig.getVault(), lenderPremium);
        emit LenderPremiumPaid(_currentEpochStart(), tokenId, lenderPremium, _portfolioFactory.ownerOf(address(this)), address(asset));
        return lenderPremium;
    }

    function _payProtocolFee(uint256 tokenId, uint256 rewardsAmount, address asset) internal returns (uint256) {
        uint256 protocolFee = (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getTreasuryFee()) / 10000;

        IERC20(asset).safeTransfer(_portfolioAccountConfig.owner(), protocolFee);
        emit ProtocolFeePaid(_currentEpochStart(), tokenId, protocolFee, _portfolioFactory.ownerOf(address(this)), address(asset));
        return protocolFee;
    }

    struct SwapRoute {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
    }

    /**
     * @dev Calculate the swap routes needed for processRewards.
     * Returns the inputToken, outputToken, and inputAmount for each of the 3 swap slots:
     *   [0] RewardsOption swap (e.g. IncreaseCollateral or InvestToVault with different asset)
     *   [1] IncreaseCollateral percentage swap (zero-balance only)
     *   [2] FinalRewardsOption swap (zero-balance only)
     * Routes with inputAmount == 0 require no swap.
     */
    function calculateRoutes(uint256 rewardsAmount, uint256 gasReclamation) external view returns (SwapRoute[3] memory routes) {
        address asset = getRewardsToken();
        address lockedAsset = _votingEscrow.token();
        bool hasDebt = CollateralFacet(address(this)).getTotalDebt() > 0;

        // 1. Compute fees
        uint256 remaining = rewardsAmount;
        if(hasDebt) {
            remaining -= (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getTreasuryFee()) / 10000;
            remaining -= (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getLenderPremium()) / 10000;
        } else {
            remaining -= (rewardsAmount * _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee()) / 10000;
        }
        uint256 postFeesAmount = remaining;

        // 2. Gas reclamation
        if(gasReclamation > 0) {
            uint256 gasReclamationCap = rewardsAmount * 5 / 100;
            if(gasReclamation > gasReclamationCap) {
                gasReclamation = gasReclamationCap;
            }
            remaining -= gasReclamation;
        }

        // 3. Slot[0]: RewardsOption
        uint256 rewardsOptionPercentage = getRewardsOptionPercentage();
        if(rewardsOptionPercentage > 0) {
            uint256 optionAmount = postFeesAmount * rewardsOptionPercentage / 100;
            if(optionAmount > remaining) {
                optionAmount = remaining;
            }
            UserRewardsConfig.RewardsOption rewardsOption = getRewardsOption();
            routes[0] = _routeForOption(rewardsOption, optionAmount, asset, lockedAsset);
            remaining -= optionAmount;
        }

        // 4. Slots[1] and [2] only apply to zero-balance flow
        if(!hasDebt) {
            // Slot[1]: IncreaseCollateral percentage
            uint256 increaseCollateralPercentage = getIncreaseCollateralPercentage();
            if(increaseCollateralPercentage > 0 && remaining > 0) {
                uint256 collateralAmount = postFeesAmount * increaseCollateralPercentage / 100;
                if(collateralAmount > remaining) {
                    collateralAmount = remaining;
                }
                routes[1] = SwapRoute(asset, lockedAsset, collateralAmount);
                remaining -= collateralAmount;
            }

            // Slot[2]: FinalRewardsOption
            if(remaining > 0) {
                UserRewardsConfig.RewardsOption finalOption = getFinalRewardsOption();
                routes[2] = _routeForOption(finalOption, remaining, asset, lockedAsset);
            }
        }
    }

    function _routeForOption(UserRewardsConfig.RewardsOption option, uint256 amount, address asset, address lockedAsset) internal view returns (SwapRoute memory route) {
        if(option == UserRewardsConfig.RewardsOption.IncreaseCollateral) {
            if(asset != lockedAsset) {
                return SwapRoute(asset, lockedAsset, amount);
            }
        } else if(option == UserRewardsConfig.RewardsOption.InvestToVault) {
            IERC4626 vault = IERC4626(UserRewardsConfig.getVaultForInvesting());
            if(address(vault) == address(0)) {
                vault = _vault;
            }
            address vaultAsset = vault.asset();
            if(asset != vaultAsset) {
                return SwapRoute(asset, vaultAsset, amount);
            }
        }
        // PayBalance, PayToRecipient, PayDebt, or same-token options need no swap
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

