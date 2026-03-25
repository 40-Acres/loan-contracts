// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ERC4626CollateralManager} from "./ERC4626CollateralManager.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";

/**
 * @title ERC4626ClaimingFacet
 * @dev Facet for claiming yield from ERC4626 vault shares used as collateral.
 * Uses ERC4626CollateralManager for storage tracking.
 *
 * Flow:
 * 1. User deposits ERC4626 shares as collateral via ERC4626CollateralFacet
 * 2. Over time, shares appreciate in value (yield accumulates)
 * 3. User/authorized caller claims yield via claimVaultYield():
 *    - Calculates current asset value of shares
 *    - Subtracts original deposit value to get yield
 *    - Redeems shares worth the yield amount
 *    - Returns assets to contract for further processing
 */
contract ERC4626ClaimingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IERC4626 public immutable _vault;

    // Events
    event VaultYieldClaimed(address indexed vault, uint256 yieldAssets, uint256 sharesRedeemed, address asset, address indexed owner);

    constructor(address portfolioFactory, address vault) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(vault != address(0), "Invalid vault");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _vault = IERC4626(vault);
    }

    // ============ Yield Claiming ============

    /**
     * @dev Claim vault yield - redeems shares representing accumulated yield
     * Returns the underlying assets to this contract for further processing
     * @return yieldAssets The amount of yield claimed (in underlying assets)
     */
    function claimVaultYield() external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 yieldAssets) {
        address vault = address(_vault);

        // Get collateral info from ERC4626CollateralManager
        (uint256 trackedShares, uint256 depositedAssets, uint256 currentAssets) =
            ERC4626CollateralManager.getCollateral(vault);

        require(trackedShares > 0, "No shares deposited");

        // Calculate yield (current value - original deposit value)
        require(currentAssets > depositedAssets, "No yield to harvest");

        // Use previewWithdraw (rounds up shares) to ensure we keep enough to cover principal
        uint256 sharesNeededForDeposit = IERC4626(vault).previewWithdraw(depositedAssets);
        uint256 sharesToRedeem = trackedShares - sharesNeededForDeposit;
        require(sharesToRedeem > 0, "Yield too small to harvest");

        // Redeem shares for underlying assets
        address vaultAsset = IERC4626(vault).asset();
        uint256 assetsReceived = IERC4626(vault).redeem(sharesToRedeem, address(this), address(this));

        // Update collateral tracking - remove redeemed shares
        // Note: This reduces shares but keeps depositedAssets the same (we're only removing yield)
        ERC4626CollateralManager.removeSharesForYield(address(_portfolioFactory.portfolioFactoryConfig()), vault, sharesToRedeem);

        emit VaultYieldClaimed(vault, assetsReceived, sharesToRedeem, vaultAsset, _portfolioFactory.ownerOf(address(this)));

        return assetsReceived;
    }

    // ============ View Functions ============

    /**
     * @dev Get the current yield available to harvest
     * @return yieldAssets The yield in underlying assets (what you'll receive)
     * @return yieldShares The shares that would be redeemed for the yield
     */
    function getAvailableYield() external view returns (uint256 yieldAssets, uint256 yieldShares) {
        address vault = address(_vault);

        (uint256 trackedShares, uint256 depositedAssets, uint256 currentAssets) =
            ERC4626CollateralManager.getCollateral(vault);

        if (trackedShares == 0) {
            return (0, 0);
        }

        if (currentAssets <= depositedAssets) {
            return (0, 0);
        }

        // Must match claimVaultYield: previewWithdraw rounds up to protect principal
        uint256 sharesNeededForDeposit = IERC4626(vault).previewWithdraw(depositedAssets);
        if (trackedShares <= sharesNeededForDeposit) {
            return (0, 0);
        }
        yieldShares = trackedShares - sharesNeededForDeposit;

        // Calculate actual assets that would be received from redeeming those shares
        yieldAssets = IERC4626(vault).convertToAssets(yieldShares);
    }

    /**
     * @dev Get deposit info for the collateral vault
     * @return vault The vault address
     * @return shares Total tracked shares
     * @return depositedAssets Original asset value at deposit time
     * @return currentAssets Current asset value of shares
     */
    function getDepositInfo() external view returns (
        address vault,
        uint256 shares,
        uint256 depositedAssets,
        uint256 currentAssets
    ) {
        vault = address(_vault);
        (shares, depositedAssets, currentAssets) = ERC4626CollateralManager.getCollateral(vault);
    }
}
