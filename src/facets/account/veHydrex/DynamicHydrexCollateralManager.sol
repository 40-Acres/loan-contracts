// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";

import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {ILendingVault} from "../../../interfaces/ILendingVault.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {HydrexPortfolioFactoryConfig} from "./HydrexPortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DynamicHydrexCollateralManager
 * @dev Hydrex veNFT collateral manager paired with DynamicFeesVault-backed debt.
 *      Reads debt directly from the vault. Reads lock value via
 *      IHydrexVotingEscrow.lockDetails(tokenId).amount (uint256).
 */
library DynamicHydrexCollateralManager {
    error InsufficientCollateral();
    error InvalidLockedCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotPortfolioManager();
    error NotSupported();
    event CollateralAdded(uint256 indexed tokenId, address indexed owner);
    event CollateralRemoved(uint256 indexed tokenId, address indexed owner);

    struct CollateralManagerData {
        mapping(uint256 tokenId => uint256 lockedCollateral) lockedCollaterals;
        mapping(uint256 tokenId => uint256 originTimestamp) originTimestamps;
        uint256 totalLockedCollateral;
        uint256 overSuppliedVaultDebt;
        uint256 undercollateralizedDebt;
    }

    function _getCollateralManagerData() internal pure returns (CollateralManagerData storage collateralManagerData) {
        bytes32 position = keccak256("storage.DynamicHydrexCollateralManager");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function addLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (previousLockedCollateral != 0) {
            return;
        }

        uint256 locked = IHydrexVotingEscrow(ve).lockDetails(tokenId).amount;
        require(locked > 0, "Locked collateral amount must be greater than 0");
        require(
            locked >= PortfolioFactoryConfig(portfolioFactoryConfig).getMinimumCollateral(),
            "Amount below minimum collateral"
        );

        _addLockedCollateral(portfolioFactoryConfig, tokenId, ve);

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    /// @notice Track collateral without the user-facing minimum gate. Reserved for the
    ///         receiver hook's rebase-bucket assignment path, where the bucket is
    ///         protocol-spawned (not user-chosen) and may carry sub-minimum dust on
    ///         the first rebase emission. tokenId must be the caller's current
    ///         rebase-bucket pointer.
    function addLockedCollateralUnchecked(address portfolioFactoryConfig, uint256 tokenId, address ve) external {
        require(
            HydrexPortfolioFactoryConfig(portfolioFactoryConfig).getRebaseTokenId(address(this)) == tokenId,
            "Token is not the rebase bucket"
        );
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        if (previousLockedCollateral != 0) {
            return;
        }
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);

        _addLockedCollateral(portfolioFactoryConfig, tokenId, ve);

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function _addLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) internal {
        require(IHydrexVotingEscrow(ve).ownerOf(tokenId) == address(this), "Token not in portfolio account");
        require(ve != address(0), "Voting escrow address cannot be zero");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        uint256 newLockedCollateral = IHydrexVotingEscrow(ve).lockDetails(tokenId).amount;
        require(newLockedCollateral > 0, "Locked collateral amount must be greater than 0");

        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
        collateralManagerData.totalLockedCollateral += newLockedCollateral;
        collateralManagerData.originTimestamps[tokenId] = block.timestamp;

        _notifyCollateralAdded(portfolioFactoryConfig, ve, tokenId);
        emit CollateralAdded(tokenId, address(this));
    }

    function removeLockedCollateral(uint256 tokenId, address portfolioFactoryConfig, address ve) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        if (previousLockedCollateral == 0) {
            return;
        }
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        collateralManagerData.totalLockedCollateral -= previousLockedCollateral;
        collateralManagerData.lockedCollaterals[tokenId] = 0;
        collateralManagerData.originTimestamps[tokenId] = 0;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        uint256 totalDebt = getTotalDebt(portfolioFactoryConfig);
        require(totalDebt <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        _notifyCollateralRemoved(portfolioFactoryConfig, ve, tokenId);
        emit CollateralRemoved(tokenId, address(this));
    }

    function updateLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) external {
        require(ve != address(0), "Voting escrow address cannot be zero");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];

        if (previousLockedCollateral == 0) {
            return;
        }

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        uint256 newLockedCollateral = IHydrexVotingEscrow(ve).lockDetails(tokenId).amount;
        if (newLockedCollateral > previousLockedCollateral) {
            uint256 difference = newLockedCollateral - previousLockedCollateral;
            collateralManagerData.totalLockedCollateral += difference;
        } else {
            uint256 difference = previousLockedCollateral - newLockedCollateral;
            collateralManagerData.totalLockedCollateral -= difference;
        }

        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedCollateral;
    }

    function getTotalDebt(address portfolioFactoryConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        return lendingPool.getDebtBalance(address(this));
    }

    function getEffectiveTotalDebt(address portfolioFactoryConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        return lendingPool.getEffectiveDebtBalance(address(this));
    }

    function increaseTotalDebt(address portfolioFactoryConfig, uint256 amount)
        external
        returns (uint256 loanAmount, uint256 originationFee)
    {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        bool isAuthorizedCaller = manager.isAuthorizedCaller(msg.sender);
        if (msg.sender != address(manager) && !isAuthorizedCaller) revert NotPortfolioManager();
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        (uint256 maxLoan,) = getMaxLoan(portfolioFactoryConfig);
        if (amount > maxLoan) {
            collateralManagerData.overSuppliedVaultDebt += amount - maxLoan;
        }

        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;

        uint256 actualTotalDebt = lendingPool.getDebtBalance(address(this));
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (actualTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = actualTotalDebt - maxLoanIgnoreSupply;
        } else {
            collateralManagerData.undercollateralizedDebt = 0;
        }

        if (isAuthorizedCaller) {
            enforceCollateralRequirements();
        }

        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(address portfolioFactoryConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        address lendingAsset = lendingPool.lendingAsset();

        uint256 actualPaid;
        if (amount > 0) {
            IERC20(lendingAsset).approve(address(lendingPool), amount);
            actualPaid = lendingPool.payFromPortfolio(amount, 0);
            IERC20(lendingAsset).approve(address(lendingPool), 0);
            excess = amount - actualPaid;
        } else {
            excess = 0;
        }

        uint256 prevOverSupplied = collateralManagerData.overSuppliedVaultDebt;
        if (prevOverSupplied > 0) {
            collateralManagerData.overSuppliedVaultDebt =
                prevOverSupplied > actualPaid ? prevOverSupplied - actualPaid : 0;
        }

        uint256 actualTotalDebt = lendingPool.getDebtBalance(address(this));
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (actualTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = actualTotalDebt - maxLoanIgnoreSupply;
        } else {
            collateralManagerData.undercollateralizedDebt = 0;
        }

        return excess;
    }

    function getMaxLoan(address portfolioFactoryConfig)
        public
        view
        returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply)
    {
        uint256 totalLockedCollateral = getTotalLockedCollateral();
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        uint256 vaultTotalAssets = ILendingVault(lendingPool.lendingVault()).totalAssets();
        uint256 maxUtilizationBps = loanConfig.getMaxUtilizationBps();

        uint256 currentLoanBalance = getTotalDebt(portfolioFactoryConfig);

        return getMaxLoanByRewardsRate(
            totalLockedCollateral, rewardsRate, multiplier, vaultTotalAssets, outstandingCapital, currentLoanBalance, maxUtilizationBps
        );
    }

    function getOriginTimestamp(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.originTimestamps[tokenId];
    }

    function getLockedCollateral(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.lockedCollaterals[tokenId];
    }

    function getLoanUtilization(address portfolioFactoryConfig) public view returns (uint256) {
        uint256 totalDebt = getTotalDebt(portfolioFactoryConfig);
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100_00) / maxLoanIgnoreSupply;
    }

    function enforceCollateralRequirements() public view returns (bool success) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        if (collateralManagerData.overSuppliedVaultDebt > 0) {
            revert BadDebt(collateralManagerData.overSuppliedVaultDebt);
        }
        if (collateralManagerData.undercollateralizedDebt > 0) {
            revert UndercollateralizedDebt(collateralManagerData.undercollateralizedDebt);
        }
        return true;
    }

    function getMaxLoanByRewardsRate(
        uint256 veBalance,
        uint256 rewardsRate,
        uint256 multiplier,
        uint256 vaultTotalAssets,
        uint256 outstandingCapital,
        uint256 currentLoanBalance,
        uint256 maxUtilizationBps
    ) internal pure returns (uint256, uint256) {
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) * multiplier) / 1e12;

        uint256 maxUtilization = (vaultTotalAssets * maxUtilizationBps) / 10000;

        if (outstandingCapital >= maxUtilization) {
            return (0, maxLoanIgnoreSupply);
        }

        if (currentLoanBalance >= maxLoanIgnoreSupply) {
            return (0, maxLoanIgnoreSupply);
        }

        uint256 maxLoan = maxLoanIgnoreSupply - currentLoanBalance;

        uint256 vaultAvailableSupply = maxUtilization - outstandingCapital;
        if (maxLoan > vaultAvailableSupply) {
            maxLoan = vaultAvailableSupply;
        }

        return (maxLoan, maxLoanIgnoreSupply);
    }

    function _updateUndercollateralizedDebt(
        address portfolioFactoryConfig,
        uint256 previousMaxLoanIgnoreSupply,
        uint256 newMaxLoanIgnoreSupply
    ) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 totalDebt = getTotalDebt(portfolioFactoryConfig);

        bool isRemovingCollateral = previousMaxLoanIgnoreSupply > newMaxLoanIgnoreSupply;

        if (totalDebt <= newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = 0;
            return;
        }

        if (previousMaxLoanIgnoreSupply == newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = totalDebt - newMaxLoanIgnoreSupply;
            return;
        }

        uint256 difference;
        if (isRemovingCollateral) {
            difference = previousMaxLoanIgnoreSupply - newMaxLoanIgnoreSupply;
            collateralManagerData.undercollateralizedDebt += difference;
        } else {
            difference = newMaxLoanIgnoreSupply - previousMaxLoanIgnoreSupply;
            if (collateralManagerData.undercollateralizedDebt < difference) {
                collateralManagerData.undercollateralizedDebt = 0;
            } else {
                collateralManagerData.undercollateralizedDebt -= difference;
            }
        }
    }

    function _notifyCollateralAdded(address portfolioFactoryConfig, address ve, uint256 tokenId) internal {
        try PortfolioFactoryConfig(portfolioFactoryConfig).onCollateralAdded(ve, tokenId) {} catch {}
    }

    function _notifyCollateralRemoved(address portfolioFactoryConfig, address ve, uint256 tokenId) internal {
        try PortfolioFactoryConfig(portfolioFactoryConfig).onCollateralRemoved(ve, tokenId) {} catch {}
    }

    function getRequiredPaymentForCollateralRemoval(address portfolioFactoryConfig, uint256 tokenId)
        public
        view
        returns (uint256)
    {
        CollateralManagerData storage data = _getCollateralManagerData();
        uint256 currentDebt = getEffectiveTotalDebt(portfolioFactoryConfig);
        if (currentDebt == 0) return 0;

        uint256 nftCollateral = data.lockedCollaterals[tokenId];
        if (nftCollateral == 0) return 0;

        uint256 newTotalCollateral = data.totalLockedCollateral - nftCollateral;

        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        uint256 newMaxLoanIgnoreSupply = (((newTotalCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;

        if (currentDebt <= newMaxLoanIgnoreSupply) return 0;

        return currentDebt - newMaxLoanIgnoreSupply;
    }
}
