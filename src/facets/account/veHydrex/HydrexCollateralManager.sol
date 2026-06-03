// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";

import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {HydrexPortfolioFactoryConfig} from "./HydrexPortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title HydrexCollateralManager
 * @dev CollateralManager variant for Hydrex veNFTs.
 *      Reads lock value via IHydrexVotingEscrow.lockDetails(tokenId).amount (uint256).
 *      Does not enforce permanent-lock conversion on insert: ROLLING and PERMANENT
 *      are both non-decaying on Hydrex, NON_PERMANENT is rejected by the facet hook.
 */
library HydrexCollateralManager {
    error InsufficientCollateral();
    error InvalidLockedCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotPortfolioManager();
    event CollateralAdded(uint256 indexed tokenId, address indexed owner);
    event CollateralRemoved(uint256 indexed tokenId, address indexed owner);

    struct CollateralManagerData {
        mapping(uint256 tokenId => uint256 lockedCollateral) lockedCollaterals;
        mapping(uint256 tokenId => uint256 originTimestamp) originTimestamps;
        uint256 totalLockedCollateral;
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 undercollateralizedDebt;
    }

    function _getCollateralManagerData() internal pure returns (CollateralManagerData storage collateralManagerData) {
        bytes32 position = keccak256("storage.HydrexCollateralManager");
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
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
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
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function _addLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) internal {
        require(IHydrexVotingEscrow(ve).ownerOf(tokenId) == address(this), "Token not in portfolio account");
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
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        uint256 totalDebt = collateralManagerData.debt;
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
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedCollateral;
    }

    function getTotalDebt() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.debt;
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

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (amount > maxLoan) {
            collateralManagerData.overSuppliedVaultDebt += amount - maxLoan;
        }

        uint256 projectedTotalDebt = collateralManagerData.debt + amount;
        if (projectedTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = projectedTotalDebt - maxLoanIgnoreSupply;
        }
        collateralManagerData.debt += amount;
        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;

        if (isAuthorizedCaller) {
            enforceCollateralRequirements();
        }

        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(address portfolioFactoryConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        uint256 totalDebt = collateralManagerData.debt;
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), balancePayment);
        uint256 actualPaid = lendingPool.payFromPortfolio(balancePayment, 0);
        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), 0);

        collateralManagerData.debt -= actualPaid;
        excess = amount - actualPaid;

        if (collateralManagerData.overSuppliedVaultDebt > 0) {
            collateralManagerData.overSuppliedVaultDebt -=
                collateralManagerData.overSuppliedVaultDebt > actualPaid ? actualPaid : collateralManagerData.overSuppliedVaultDebt;
        }

        if (collateralManagerData.undercollateralizedDebt > 0) {
            collateralManagerData.undercollateralizedDebt -=
                collateralManagerData.undercollateralizedDebt > actualPaid ? actualPaid : collateralManagerData.undercollateralizedDebt;
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

        if (address(loanConfig) == address(0)) {
            return (0, 0);
        }

        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        address loanContract = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract();
        uint256 outstandingCapital;
        uint256 vaultBalance;
        if (loanContract != address(0)) {
            ILendingPool lendingPool = ILendingPool(loanContract);
            outstandingCapital = lendingPool.activeAssets();

            address vault = lendingPool.lendingVault();
            if (vault != address(0)) {
                address underlyingAsset = IERC4626(vault).asset();
                vaultBalance = IERC20(underlyingAsset).balanceOf(vault);
            }
        }

        uint256 currentLoanBalance = getTotalDebt();
        uint256 maxUtilizationBps = loanConfig.getMaxUtilizationBps();

        return getMaxLoanByRewardsRate(
            totalLockedCollateral, rewardsRate, multiplier, vaultBalance, outstandingCapital, currentLoanBalance, maxUtilizationBps
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
        uint256 totalDebt = getTotalDebt();
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
        uint256 vaultBalance,
        uint256 outstandingCapital,
        uint256 currentLoanBalance,
        uint256 maxUtilizationBps
    ) internal pure returns (uint256, uint256) {
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) * multiplier) / 1e12;

        uint256 vaultSupply = vaultBalance + outstandingCapital;
        uint256 maxUtilization = (vaultSupply * maxUtilizationBps) / 10000;

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

    function _updateUndercollateralizedDebt(uint256 previousMaxLoanIgnoreSupply, uint256 newMaxLoanIgnoreSupply) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 totalDebt = collateralManagerData.debt;

        bool isRemovingCollateral = previousMaxLoanIgnoreSupply > newMaxLoanIgnoreSupply;

        if (totalDebt <= newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = 0;
            return;
        }

        // prev == new means borrowing capacity is unchanged; leave the delta tracker alone (no-op).

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
        uint256 currentDebt = data.debt;
        if (currentDebt == 0) return 0;

        uint256 nftCollateral = data.lockedCollaterals[tokenId];
        if (nftCollateral == 0) return 0;

        require(data.lockedCollaterals[tokenId] != 0, "HydrexCollateralManager: token not locked");
        uint256 newTotalCollateral = data.totalLockedCollateral - nftCollateral;

        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        uint256 newMaxLoanIgnoreSupply = (((newTotalCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;

        if (currentDebt <= newMaxLoanIgnoreSupply) return 0;

        return currentDebt - newMaxLoanIgnoreSupply;
    }
}
