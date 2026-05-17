// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {UserRewardsConfig} from "./UserRewardsConfig.sol";
import {SwapMod} from "../swap/SwapMod.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
import {IPortfolioManager} from "../../../accounts/IPortfolioManager.sol";

interface ILendingFacet {
    function pay(uint256 amount) external returns (uint256 excess);
}

/**
 * @title RewardsProcessingFacet
 * @dev Facet that processes rewards for a portfolio account.
 *      Config getters/setters are in RewardsConfigFacet.
 */
contract RewardsProcessingFacet is AccessControl {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    SwapConfig public immutable _swapConfig;
    address public immutable _underlyingLockedAsset;
    IERC4626 public immutable _vault;
    address public immutable _defaultToken;

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
    event TransferFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);
    event CollateralIncreased(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);
    event ActiveBalanceRewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event SwapFailed(uint256 epoch, uint256 indexed tokenId, uint256 inputAmount, address inputToken, address outputToken, address indexed owner);
    event InvestToVaultFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);
    event IncreaseCollateralFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);

    constructor(address portfolioFactory, address swapConfig, address underlyingLockedAsset, address vault, address defaultToken) {
        require(portfolioFactory != address(0));
        require(swapConfig != address(0));
        require(underlyingLockedAsset != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _swapConfig = SwapConfig(swapConfig);
        _underlyingLockedAsset = underlyingLockedAsset;
        _vault = IERC4626(vault);
        _defaultToken = defaultToken;
    }

    /**
    @dev Main entry point for processing rewards.
    The processing flow is:
    1. Pay protocol fee and lender premium
    2. Handle gas reclamation
    3. Branch: borrower (active balance distribution → debt repayment → excess to vault)
              or zero-balance (zero balance distribution → remainder to recipient)
     */
    function processRewards(uint256 tokenId, uint256 rewardsAmount, SwapMod.RouteParams[4] memory swapParams, uint256 gasReclamation) external onlyAuthorizedCaller(_portfolioFactory) {
        address asset = getRewardsToken();
        emit RewardsProcessed(_currentEpochStart(), tokenId, rewardsAmount, _portfolioFactory.ownerOf(address(this)), asset);
        require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount && rewardsAmount > 0);

        // 1. Fees first — computed on original rewardsAmount
        uint256 remaining = rewardsAmount;
        bool hasDebt = _getTotalDebt() > 0;
        if (hasDebt) {
            remaining -= _payProtocolFee(tokenId, rewardsAmount, asset);
            remaining -= _payLenderPremium(tokenId, rewardsAmount, asset);
        } else {
            remaining -= _payZeroBalanceFee(tokenId, rewardsAmount, asset);
        }

        // Post-fees amount is the base for percentage calculations
        uint256 postFeesAmount = remaining;

        // 2. Gas reclamation — cap computed on original rewardsAmount
        remaining = _handleGasReclamation(tokenId, rewardsAmount, asset, gasReclamation, remaining);

        // 3. Branch based on debt status
        if (hasDebt) {
            // Only allow active balance distribution if utilization <= 100 (debt <= maxLoanIgnoreSupply).
            // Underwater accounts (utilization > 100) send 100% of post-fees rewards to debt repayment.
            if (_getLoanUtilization() <= 100 && UserRewardsConfig.hasActiveBalanceDistribution()) {
                remaining = _processActiveBalanceDistribution(tokenId, rewardsAmount, remaining, asset, swapParams[0]);
            }
            remaining = _processActiveLoanRewards(tokenId, remaining, asset);
            if (remaining > 0) {
                _depositRemainingToVault(remaining, asset);
            }
        } else {
            _processZeroBalanceDistribution(tokenId, postFeesAmount, remaining, asset, swapParams);
        }
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

    function _depositRemainingToVault(uint256 amount, address asset) internal {
        if (address(_vault) == address(0)) {
            _sendToWalletAccount(asset, amount);
            return;
        }
        address vaultAddress = address(_vault);
        address recipient = _portfolioFactory.ownerOf(address(this));
        IERC20(asset).approve(vaultAddress, amount);
        try _vault.deposit(amount, recipient) {
        } catch {
            _sendToWalletAccount(asset, amount);
            emit InvestToVaultFailed(_currentEpochStart(), 0, amount, asset, recipient);
        }
        IERC20(asset).approve(vaultAddress, 0);
    }

    /**
        * @dev Returns the rewards token to use for the rewards processing.
        *      Priority: vault asset (if vault set) > default token
     */
    function getRewardsToken() public view returns (address) {
        if (address(_vault) != address(0)) {
            return _vault.asset();
        }

        return _defaultToken;
    }

    function _processActiveLoanRewards(uint256 tokenId, uint256 availableAmount, address asset) internal virtual returns (uint256 remaining) {
        require(IERC20(asset).balanceOf(address(this)) >= availableAmount);
        address loanContract = _portfolioFactory.portfolioFactoryConfig().getLoanContract();
        require(loanContract != address(0));

        uint256 excess = _decreaseTotalDebt(availableAmount);
        emit LoanPaid(_currentEpochStart(), tokenId, availableAmount-excess, _portfolioFactory.ownerOf(address(this)), address(asset));

        return excess;
    }

    function _getTotalDebt() internal view virtual returns (uint256) {
        return CollateralManager.getTotalDebt();
    }

    /**
     * @dev Returns loan utilization: 0 = no debt, 100 = at capacity, >100 = underwater.
     *      Used to gate active balance distribution (disabled when > 100) and
     *      can be used for liquidation thresholds (e.g. 150).
     */
    function _getLoanUtilization() internal view virtual returns (uint256) {
        return CollateralManager.getLoanUtilization(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function _decreaseTotalDebt(uint256 amount) internal virtual returns (uint256 excess) {
        return CollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), amount);
    }

    function _processZeroBalanceDistribution(
        uint256 tokenId, uint256 postFeesAmount, uint256 remaining,
        address asset, SwapMod.RouteParams[4] memory swapParams
    ) internal {
        // Use remaining (post-gas) as the base for percentage splits
        uint256 distributable = remaining;
        uint8 count = UserRewardsConfig.getZeroBalanceDistributionCount();
        for (uint8 i = 0; i < count; i++) {
            if (remaining == 0) break;
            UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getZeroBalanceDistributionEntry(i);
            uint256 entryAmount = distributable * entry.percentage / 100;
            if (entryAmount > remaining) entryAmount = remaining;
            uint256 used = _executeDistributionEntry(tokenId, entry, entryAmount, asset, swapParams[i]);
            remaining -= used;
        }
        // Remainder → default recipient
        if (remaining > 0) {
            bool success = IERC20(asset).trySafeTransfer(_getRecipient(), remaining);
            if (!success) {
                _sendToWalletAccount(asset, remaining);
                emit TransferFailed(_currentEpochStart(), tokenId, remaining, _getRecipient(), asset, _portfolioFactory.ownerOf(address(this)));
            }
        }
        emit ZeroBalanceRewardsProcessed(_currentEpochStart(), tokenId, postFeesAmount, _getRecipient(), asset, _portfolioFactory.ownerOf(address(this)));
    }

    function _processActiveBalanceDistribution(
        uint256 tokenId, uint256 rewardsAmount, uint256 remaining,
        address asset, SwapMod.RouteParams memory swapParams
    ) internal returns (uint256) {
        if (remaining == 0) return remaining;
        UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getActiveBalanceDistribution();
        uint256 entryAmount = rewardsAmount * entry.percentage / 100;
        if (entryAmount > remaining) entryAmount = remaining;
        uint256 used = _executeDistributionEntry(tokenId, entry, entryAmount, asset, swapParams);
        remaining -= used;
        emit ActiveBalanceRewardsProcessed(_currentEpochStart(), tokenId, used, asset, _portfolioFactory.ownerOf(address(this)));
        return remaining;  // remainder → debt repayment (caller handles)
    }

    function _executeDistributionEntry(
        uint256 tokenId, UserRewardsConfig.DistributionEntry memory entry,
        uint256 amount, address asset, SwapMod.RouteParams memory swapParams
    ) internal returns (uint256 used) {
        if (entry.option == UserRewardsConfig.RewardsOption.IncreaseCollateral) {
            return _increaseCollateral(tokenId, asset, amount, swapParams);
        } else if (entry.option == UserRewardsConfig.RewardsOption.InvestToVault) {
            return _investToVaultTarget(tokenId, amount, asset, swapParams, entry.target);
        } else if (entry.option == UserRewardsConfig.RewardsOption.PayToRecipient) {
            return _payToRecipientWithToken(tokenId, amount, asset, entry, swapParams);
        } else if (entry.option == UserRewardsConfig.RewardsOption.PayDebt) {
            return _payDebtToTarget(tokenId, amount, asset, entry.target);
        } else {
            // PayBalance — transfer to target or default recipient
            address target = entry.target != address(0) ? entry.target : _getRecipient();
            bool success = IERC20(asset).trySafeTransfer(target, amount);
            if (!success) {
                uint256 walletUsed = _sendToWalletAccount(asset, amount);
                emit TransferFailed(_currentEpochStart(), tokenId, amount, target, asset, _portfolioFactory.ownerOf(address(this)));
                if (walletUsed == 0) return 0;
            }
            return amount;
        }
    }

    function _payToRecipientWithToken(
        uint256 tokenId, uint256 amount, address asset,
        UserRewardsConfig.DistributionEntry memory entry,
        SwapMod.RouteParams memory swapParams
    ) internal returns (uint256 amountUsed) {
        address recipient = entry.target != address(0) ? entry.target : _getRecipient();
        address outputToken = entry.outputToken != address(0) ? entry.outputToken : asset;

        if (outputToken != asset) {
            // Swap must succeed — reverts on failure
            uint256 swappedAmount = SwapMod.swap(SwapMod.RouteParams({
                swapConfig: address(_swapConfig),
                swapTarget: swapParams.swapTarget,
                swapData: swapParams.swapData,
                inputToken: asset,
                inputAmount: amount,
                outputToken: outputToken,
                minimumOutputAmount: swapParams.minimumOutputAmount
            }));
            // Try transfer; if recipient is blacklisted, send to wallet account
            bool success = IERC20(outputToken).trySafeTransfer(recipient, swappedAmount);
            if (!success) {
                uint256 walletUsed = _sendToWalletAccount(outputToken, swappedAmount);
                emit TransferFailed(_currentEpochStart(), tokenId, swappedAmount, recipient, outputToken, _portfolioFactory.ownerOf(address(this)));
                if (walletUsed == 0) return 0;
            }
        } else {
            // Try transfer; if recipient is blacklisted, send to wallet account
            bool success = IERC20(asset).trySafeTransfer(recipient, amount);
            if (!success) {
                uint256 walletUsed = _sendToWalletAccount(asset, amount);
                emit TransferFailed(_currentEpochStart(), tokenId, amount, recipient, asset, _portfolioFactory.ownerOf(address(this)));
                if (walletUsed == 0) return 0;
            }
        }

        emit PaidToRecipient(_currentEpochStart(), tokenId, amount, recipient, asset, _portfolioFactory.ownerOf(address(this)));
        return amount;
    }

    function _sendToWalletAccount(address token, uint256 amount) internal returns (uint256 amountUsed) {
        IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
        address walletFactory = portfolioManager.factoryBySalt(bytes32(0));
        if (walletFactory == address(0)) return 0;
        address owner = _portfolioFactory.ownerOf(address(this));
        address walletAccount = PortfolioFactory(walletFactory).portfolioOf(owner);
        if (walletAccount == address(0)) return 0;
        bool success = IERC20(token).trySafeTransfer(walletAccount, amount);
        return success ? amount : 0;
    }

    function _investToVaultTarget(
        uint256 tokenId, uint256 optionAmount, address asset,
        SwapMod.RouteParams memory swapParams, address vaultAddress
    ) internal returns (uint256 amountUsed) {
        IERC4626 vault;
        if (vaultAddress != address(0)) {
            vault = IERC4626(vaultAddress);
        } else {
            vault = IERC4626(UserRewardsConfig.getVaultForInvesting());
            if (address(vault) == address(0)) {
                vault = _vault;
            }
        }
        address vaultAsset = vault.asset();
        uint256 actualAmountToInvest = optionAmount;

        if (asset != vaultAsset) {
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
        uint256 amountToDeposit = vaultAssetBalance < actualAmountToInvest ? vaultAssetBalance : actualAmountToInvest;

        IERC20(vaultAsset).approve(address(vault), amountToDeposit);
        address recipient = _portfolioFactory.ownerOf(address(this));
        try vault.deposit(amountToDeposit, recipient) {
            emit InvestedToVault(_currentEpochStart(), tokenId, amountToDeposit, asset, recipient);
        } catch {
            emit InvestToVaultFailed(_currentEpochStart(), tokenId, amountToDeposit, asset, recipient);
            IERC20(vaultAsset).approve(address(vault), 0);
            if (asset != vaultAsset) {
                // Swap already happened — original tokens are gone, send swapped tokens to wallet
                _sendToWalletAccount(vaultAsset, amountToDeposit);
                return optionAmount;
            }
            return 0;
        }
        IERC20(vaultAsset).approve(address(vault), 0);

        return optionAmount;
    }

    function _payDebtToTarget(uint256 tokenId, uint256 amountToPay, address asset, address portfolioFactory) internal returns (uint256 amountPaid) {
        if (portfolioFactory == address(0)) {
            return 0;
        }

        IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
        require(portfolioManager.isRegisteredFactory(portfolioFactory), "PayDebt target must be registered factory");

        address owner = _portfolioFactory.ownerOf(address(this));
        address target = PortfolioFactory(portfolioFactory).portfolioOf(owner);

        if (target == address(0)) {
            return 0;
        }

        require(portfolioManager.isPortfolioRegistered(target), "PayDebt target must be registered portfolio");

        IERC20(asset).approve(target, amountToPay);
        try ILendingFacet(target).pay(amountToPay) returns (uint256 excess) {
            amountPaid = amountToPay - excess;
            emit DebtPaid(_currentEpochStart(), tokenId, amountPaid, target, asset);
        } catch {
            amountPaid = 0;
        }
        IERC20(asset).approve(target, 0);
        return amountPaid;
    }

    function _increaseCollateral(uint256 tokenId, address rewardsToken, uint256 optionAmount, SwapMod.RouteParams memory swapParams) internal virtual returns (uint256 amountUsed) {
        address lockedAsset = _underlyingLockedAsset;
        uint256 beginningLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        if(rewardsToken == lockedAsset) {
            uint256 used = _increaseLock(tokenId, optionAmount, lockedAsset);
            // No swap happened — return 0 so tokens stay in remaining
            return used;
        }

        require(swapParams.swapTarget != address(0), "Swap target must be provided");
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
        uint256 used = _increaseLock(tokenId, increaseAmount, lockedAsset);
        if (used == 0) {
            // Swap already happened — original tokens are gone, send swapped tokens to wallet
            _sendToWalletAccount(lockedAsset, increaseAmount);
        }
        return optionAmount;
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) internal virtual returns (uint256 usedAmount) {
        return 0;
    }

    /**
     * @dev Returns true if the input token is allowed for swapping.
     *      Returns true by default — override in subclasses to block specific tokens.
     */
    function _isSwapAllowed(address) internal view virtual returns (bool) {
        return true;
    }

    function swapToRewardsToken(SwapMod.RouteParams memory params) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 amount) {
        require(_isSwapAllowed(params.inputToken), "Input token not allowed");
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
        PortfolioFactoryConfig config = _portfolioFactory.portfolioFactoryConfig();
        uint256 zeroBalanceFee = (rewardsAmount * config.getLoanConfig().getZeroBalanceFee()) / 10000;
        IERC20(asset).safeTransfer(config.getLoanConfig().getTreasury(), zeroBalanceFee);
        emit ZeroBalanceFeePaid(_currentEpochStart(), tokenId, zeroBalanceFee, _portfolioFactory.ownerOf(address(this)), address(asset));
        return zeroBalanceFee;
    }

    function swapToRewardsTokenMultiple(SwapMod.RouteParams[] memory params) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 amount) {
        address rewardsToken = getRewardsToken();
        for(uint256 i = 0; i < params.length; i++) {
            if (params[i].inputToken == rewardsToken) continue;
            if (!_isSwapAllowed(params[i].inputToken)) continue;
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
                emit SwapFailed(_currentEpochStart(), 0, params[i].inputAmount, params[i].inputToken, rewardsToken, _portfolioFactory.ownerOf(address(this)));
                continue;
            }
        }
        return amount;
    }


    /**
     * @dev Pays the lender premium from the rewards amount to the lending pool.
     * @notice For Dynamic Fees the entirety of rewards are sent to vault and lender premium is decided by vault utilization
     * @param tokenId The ID of the portfolio token.
     * @param rewardsAmount The amount of rewards to pay the lender premium from.
     * @param asset The asset in which the rewards are denominated.
     * @return The amount of lender premium paid.
     */
    function _payLenderPremium(uint256 tokenId, uint256 rewardsAmount, address asset) internal returns (uint256) {
        PortfolioFactoryConfig config = _portfolioFactory.portfolioFactoryConfig();
        uint256 lenderPremium = (rewardsAmount * config.getLoanConfig().getLenderPremium()) / 10000;

        address loanContract = config.getLoanContract();
        IERC20(asset).forceApprove(loanContract, lenderPremium);
        ILendingPool(loanContract).depositRewards(lenderPremium);
        IERC20(asset).approve(loanContract, 0);
        emit LenderPremiumPaid(_currentEpochStart(), tokenId, lenderPremium, _portfolioFactory.ownerOf(address(this)), address(asset));
        return lenderPremium;
    }

    function _payProtocolFee(uint256 tokenId, uint256 rewardsAmount, address asset) internal returns (uint256) {
        PortfolioFactoryConfig config = _portfolioFactory.portfolioFactoryConfig();
        uint256 protocolFee = (rewardsAmount * config.getLoanConfig().getTreasuryFee()) / 10000;

        IERC20(asset).safeTransfer(config.getLoanConfig().getTreasury(), protocolFee);
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
     * Returns the inputToken, outputToken, and inputAmount for each of the 4 swap slots.
     *
     * Borrower (hasDebt):
     *   [0] Active balance distribution entry swap (if set)
     *
     * Zero-balance (!hasDebt):
     *   [0..3] Each slot corresponds to a zero-balance distribution entry
     *
     * Routes with inputAmount == 0 require no swap.
     */
    function calculateRoutes(uint256 tokenId, uint256 rewardsAmount, uint256 gasReclamation) external view returns (SwapRoute[4] memory routes) {
        address asset = getRewardsToken();
        address lockedAsset = _underlyingLockedAsset;
        bool hasDebt = _getTotalDebt() > 0;

        uint256 remaining = rewardsAmount;
        {
            PortfolioFactoryConfig config = _portfolioFactory.portfolioFactoryConfig();
            if(hasDebt) {
                remaining -= (rewardsAmount * config.getLoanConfig().getTreasuryFee()) / 10000;
                remaining -= (rewardsAmount * config.getLoanConfig().getLenderPremium()) / 10000;
            } else {
                remaining -= (rewardsAmount * config.getLoanConfig().getZeroBalanceFee()) / 10000;
            }
        }

        if(gasReclamation > 0) {
            uint256 gasReclamationCap = rewardsAmount * 5 / 100;
            if(gasReclamation > gasReclamationCap) {
                gasReclamation = gasReclamationCap;
            }
            remaining -= gasReclamation;
        }

        if (hasDebt) {
            routes[0] = _buildActiveBalanceRoute(rewardsAmount, remaining, asset, lockedAsset, tokenId);
        } else {
            uint256 distributable = remaining;
            uint8 count = UserRewardsConfig.getZeroBalanceDistributionCount();
            for (uint8 i = 0; i < count; i++) {
                if (remaining == 0) break;
                (routes[i], remaining) = _buildZeroBalanceRoute(i, distributable, remaining, asset, lockedAsset, tokenId);
            }
        }
    }

    function _buildActiveBalanceRoute(
        uint256 rewardsAmount,
        uint256 remaining,
        address asset,
        address lockedAsset,
        uint256 tokenId
    ) internal view returns (SwapRoute memory route) {
        if (_getLoanUtilization() > 100 || !UserRewardsConfig.hasActiveBalanceDistribution()) return route;
        UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getActiveBalanceDistribution();
        uint256 entryAmount = rewardsAmount * entry.percentage / 100;
        if (entryAmount > remaining) entryAmount = remaining;
        return _routeForDistributionEntry(entry, entryAmount, asset, lockedAsset, tokenId);
    }

    function _buildZeroBalanceRoute(
        uint8 i,
        uint256 distributable,
        uint256 remaining,
        address asset,
        address lockedAsset,
        uint256 tokenId
    ) internal view returns (SwapRoute memory route, uint256 newRemaining) {
        UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getZeroBalanceDistributionEntry(i);
        uint256 entryAmount = distributable * entry.percentage / 100;
        if (entryAmount > remaining) entryAmount = remaining;
        route = _routeForDistributionEntry(entry, entryAmount, asset, lockedAsset, tokenId);
        newRemaining = remaining - entryAmount;
    }

    function _routeForDistributionEntry(
        UserRewardsConfig.DistributionEntry memory entry, uint256 amount,
        address asset, address lockedAsset, uint256 tokenId
    ) internal view virtual returns (SwapRoute memory route) {
        if (entry.option == UserRewardsConfig.RewardsOption.IncreaseCollateral) {
            if (asset != lockedAsset) {
                return SwapRoute(asset, lockedAsset, amount);
            }
        } else if (entry.option == UserRewardsConfig.RewardsOption.InvestToVault) {
            IERC4626 vault;
            if (entry.target != address(0)) {
                vault = IERC4626(entry.target);
            } else {
                vault = IERC4626(UserRewardsConfig.getVaultForInvesting());
                if (address(vault) == address(0)) {
                    vault = _vault;
                }
            }
            address vaultAsset = vault.asset();
            if (asset != vaultAsset) {
                return SwapRoute(asset, vaultAsset, amount);
            }
        } else if (entry.option == UserRewardsConfig.RewardsOption.PayToRecipient) {
            address outputToken = entry.outputToken != address(0) ? entry.outputToken : asset;
            if (asset != outputToken) {
                return SwapRoute(asset, outputToken, amount);
            }
        }
        // PayBalance, PayDebt, or same-token options need no swap
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
