// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
    event TransferFailed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed recipient, address asset, address indexed owner);

    event RewardsTokenSet(address rewardsToken, address indexed owner);
    event RecipientSet(address recipient, address indexed owner);
    event CollateralIncreased(uint256 epoch, uint256 indexed tokenId, uint256 amount, address indexed owner);
    event ZeroBalanceDistributionSet(uint256 entryCount, address indexed owner);
    event ActiveBalanceDistributionSet(uint256 entryCount, address indexed owner);
    event ActiveBalanceDistributionCleared(address indexed owner);
    event VaultForInvestingSet(address vault, address indexed owner);
    event ZeroBalanceDistributionCleared(address indexed owner);
    event ActiveBalanceRewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 amount, address asset, address indexed owner);

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
        bool hasDebt = CollateralFacet(address(this)).getTotalDebt() > 0;
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
            if (UserRewardsConfig.hasActiveBalanceDistribution()) {
                remaining = _processActiveBalanceDistribution(tokenId, postFeesAmount, remaining, asset, swapParams[0]);
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
        address vaultAddress = address(_vault);
        IERC20(asset).approve(vaultAddress, amount);
        _vault.deposit(amount, _portfolioFactory.ownerOf(address(this)));
        IERC20(asset).approve(vaultAddress, 0);
    }

    /**
        * @dev Returns the rewards token to use for the rewards processing.
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

        uint256 excess = CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), availableAmount);
        emit LoanPaid(_currentEpochStart(), tokenId, availableAmount, _portfolioFactory.ownerOf(address(this)), address(asset));

        return excess;
    }

    function _processZeroBalanceDistribution(
        uint256 tokenId, uint256 postFeesAmount, uint256 remaining,
        address asset, SwapMod.RouteParams[4] memory swapParams
    ) internal {
        uint8 count = UserRewardsConfig.getZeroBalanceDistributionCount();
        for (uint8 i = 0; i < count; i++) {
            if (remaining == 0) break;
            UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getZeroBalanceDistributionEntry(i);
            uint256 entryAmount = postFeesAmount * entry.percentage / 100;
            if (entryAmount > remaining) entryAmount = remaining;
            uint256 used = _executeDistributionEntry(tokenId, entry, entryAmount, asset, swapParams[i]);
            remaining -= used;
        }
        // Remainder → default recipient
        if (remaining > 0) {
            IERC20(asset).safeTransfer(_getRecipient(), remaining);
        }
        emit ZeroBalanceRewardsProcessed(_currentEpochStart(), tokenId, postFeesAmount, _getRecipient(), asset, _portfolioFactory.ownerOf(address(this)));
    }

    function _processActiveBalanceDistribution(
        uint256 tokenId, uint256 postFeesAmount, uint256 remaining,
        address asset, SwapMod.RouteParams memory swapParams
    ) internal returns (uint256) {
        if (remaining == 0) return remaining;
        UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getActiveBalanceDistribution();
        uint256 entryAmount = postFeesAmount * entry.percentage / 100;
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
                _sendToWalletAccount(asset, amount);
                emit TransferFailed(_currentEpochStart(), tokenId, amount, target, asset, _portfolioFactory.ownerOf(address(this)));
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
                _sendToWalletAccount(outputToken, swappedAmount);
                emit TransferFailed(_currentEpochStart(), tokenId, swappedAmount, recipient, outputToken, _portfolioFactory.ownerOf(address(this)));
            }
        } else {
            // Try transfer; if recipient is blacklisted, send to wallet account
            bool success = IERC20(asset).trySafeTransfer(recipient, amount);
            if (!success) {
                _sendToWalletAccount(asset, amount);
                emit TransferFailed(_currentEpochStart(), tokenId, amount, recipient, asset, _portfolioFactory.ownerOf(address(this)));
            }
        }

        emit PaidToRecipient(_currentEpochStart(), tokenId, amount, recipient, asset, _portfolioFactory.ownerOf(address(this)));
        return amount;
    }

    function _sendToWalletAccount(address token, uint256 amount) internal {
        IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
        address walletFactory = portfolioManager.factoryBySalt(bytes32(0));
        require(walletFactory != address(0), "Wallet factory not deployed");
        address owner = _portfolioFactory.ownerOf(address(this));
        address walletAccount = PortfolioFactory(walletFactory).portfolioOf(owner);
        require(walletAccount != address(0), "Wallet account not deployed");
        IERC20(token).safeTransfer(walletAccount, amount);
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
        vault.deposit(amountToDeposit, recipient);
        IERC20(vaultAsset).approve(address(vault), 0);

        emit InvestedToVault(_currentEpochStart(), tokenId, amountToDeposit, asset, recipient);
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

    function setRewardsToken(address rewardsToken) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRewardsToken(rewardsToken);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit RewardsTokenSet(rewardsToken, owner);
    }

    function setRecipient(address recipient) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRecipient(recipient);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit RecipientSet(recipient, owner);
    }

    function setVaultForInvesting(address vault) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setVaultForInvesting(vault);
        emit VaultForInvestingSet(vault, _portfolioFactory.ownerOf(address(this)));
    }

    function getVaultForInvesting() external view returns (address) {
        return UserRewardsConfig.getVaultForInvesting();
    }

    function setZeroBalanceDistribution(
        UserRewardsConfig.DistributionEntry[] calldata entries
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
        address thisOwner = _portfolioFactory.ownerOf(address(this));
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].option == UserRewardsConfig.RewardsOption.PayDebt && entries[i].target != address(0)) {
                require(portfolioManager.isRegisteredFactory(entries[i].target), "PayDebt target must be registered factory");
                address targetPortfolio = PortfolioFactory(entries[i].target).portfolioOf(thisOwner);
                require(targetPortfolio != address(0), "PayDebt target factory must have portfolio for owner");
            }
        }
        UserRewardsConfig.setZeroBalanceDistribution(entries);
        emit ZeroBalanceDistributionSet(entries.length, _portfolioFactory.ownerOf(address(this)));
    }

    function getZeroBalanceDistribution() external view returns (UserRewardsConfig.DistributionEntry[] memory) {
        uint8 count = UserRewardsConfig.getZeroBalanceDistributionCount();
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](count);
        for (uint8 i = 0; i < count; i++) {
            entries[i] = UserRewardsConfig.getZeroBalanceDistributionEntry(i);
        }
        return entries;
    }

    function clearZeroBalanceDistribution() external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.clearZeroBalanceDistribution();
        emit ZeroBalanceDistributionCleared(_portfolioFactory.ownerOf(address(this)));
    }

    function setActiveBalanceDistribution(
        UserRewardsConfig.DistributionEntry calldata entry
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        if (entry.option == UserRewardsConfig.RewardsOption.PayDebt && entry.target != address(0)) {
            IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
            address thisOwner = _portfolioFactory.ownerOf(address(this));
            require(portfolioManager.isRegisteredFactory(entry.target), "PayDebt target must be registered factory");
            address targetPortfolio = PortfolioFactory(entry.target).portfolioOf(thisOwner);
            require(targetPortfolio != address(0), "PayDebt target factory must have portfolio for owner");
        }
        UserRewardsConfig.setActiveBalanceDistribution(entry);
        emit ActiveBalanceDistributionSet(1, _portfolioFactory.ownerOf(address(this)));
    }

    function getActiveBalanceDistribution() external view returns (UserRewardsConfig.DistributionEntry memory) {
        return UserRewardsConfig.getActiveBalanceDistribution();
    }

    function clearActiveBalanceDistribution() external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.clearActiveBalanceDistribution();
        emit ActiveBalanceDistributionCleared(_portfolioFactory.ownerOf(address(this)));
    }

    function _increaseCollateral(uint256 tokenId, address rewardsToken, uint256 optionAmount, SwapMod.RouteParams memory swapParams) internal returns (uint256 amountUsed) {
        address lockedAsset = _votingEscrow.token();
        uint256 beginningLockedAssetBalance = IERC20(lockedAsset).balanceOf(address(this));
        if(rewardsToken == lockedAsset) {
            _increaseLock(tokenId, optionAmount, lockedAsset);
            return optionAmount;
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
        _increaseLock(tokenId, increaseAmount, lockedAsset);
        return optionAmount;
    }

    function _increaseLock(uint256 tokenId, uint256 increaseAmount, address lockedAsset) virtual internal {
        IERC20(lockedAsset).approve(address(_votingEscrow), increaseAmount);
        IVotingEscrow(address(_votingEscrow)).increaseAmount(tokenId, increaseAmount);
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
        IERC20(asset).safeTransfer(_portfolioAccountConfig.owner(), zeroBalanceFee);
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
    function calculateRoutes(uint256 rewardsAmount, uint256 gasReclamation) external view returns (SwapRoute[4] memory routes) {
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

        if (hasDebt) {
            if (UserRewardsConfig.hasActiveBalanceDistribution()) {
                UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getActiveBalanceDistribution();
                uint256 entryAmount = postFeesAmount * entry.percentage / 100;
                if (entryAmount > remaining) entryAmount = remaining;
                routes[0] = _routeForDistributionEntry(entry, entryAmount, asset, lockedAsset);
            }
        } else {
            uint8 count = UserRewardsConfig.getZeroBalanceDistributionCount();
            for (uint8 i = 0; i < count; i++) {
                if (remaining == 0) break;
                UserRewardsConfig.DistributionEntry memory entry = UserRewardsConfig.getZeroBalanceDistributionEntry(i);
                uint256 entryAmount = postFeesAmount * entry.percentage / 100;
                if (entryAmount > remaining) entryAmount = remaining;
                routes[i] = _routeForDistributionEntry(entry, entryAmount, asset, lockedAsset);
                remaining -= entryAmount;
            }
        }
    }

    function _routeForDistributionEntry(
        UserRewardsConfig.DistributionEntry memory entry, uint256 amount,
        address asset, address lockedAsset
    ) internal view returns (SwapRoute memory route) {
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
