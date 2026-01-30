// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {VaultDepositsStorage} from "../../../storage/VaultDepositsStorage.sol";

/**
 * @title ERC4626ClaimingFacet
 * @dev Facet for managing ERC4626 vault shares and claiming yield
 * Tracks share deposits and harvests accumulated yield
 *
 * Flow:
 * 1. User deposits ERC4626 shares via depositShares() - records shares and their asset value
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

    // Events
    event SharesDeposited(address indexed vault, uint256 shares, uint256 assets, address indexed owner);
    event SharesWithdrawn(address indexed vault, uint256 shares, uint256 assets, address indexed owner);
    event VaultYieldClaimed(address indexed vault, uint256 yieldAssets, uint256 sharesRedeemed, address asset, address indexed owner);

    constructor(address portfolioFactory) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
    }

    // ============ Share Management ============

    /**
     * @dev Deposit ERC4626 shares and track their asset value at deposit time
     * @param vault The ERC4626 vault address
     * @param shares The amount of shares to deposit
     */
    function depositShares(address vault, uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(vault != address(0), "Invalid vault");
        require(shares > 0, "Shares must be > 0");

        address owner = _portfolioFactory.ownerOf(address(this));

        // Transfer shares from owner to this contract
        IERC20(vault).safeTransferFrom(owner, address(this), shares);

        // Calculate the asset value of these shares at deposit time
        uint256 assets = IERC4626(vault).convertToAssets(shares);

        // Record the deposit
        VaultDepositsStorage.addDeposit(vault, shares, assets);

        emit SharesDeposited(vault, shares, assets, owner);
    }

    /**
     * @dev Track ERC4626 shares that are already in the wallet
     * @param vault The ERC4626 vault address
     * @param shares The amount of shares to track (must already be in wallet)
     */
    function trackExistingShares(address vault, uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(vault != address(0), "Invalid vault");
        require(shares > 0, "Shares must be > 0");
        require(IERC20(vault).balanceOf(address(this)) >= shares, "Insufficient shares in wallet");

        // Calculate the asset value of these shares at current time
        uint256 assets = IERC4626(vault).convertToAssets(shares);

        // Record the deposit
        VaultDepositsStorage.addDeposit(vault, shares, assets);

        emit SharesDeposited(vault, shares, assets, _portfolioFactory.ownerOf(address(this)));
    }

    /**
     * @dev Withdraw shares back to owner
     * @param vault The ERC4626 vault address
     * @param shares The amount of shares to withdraw
     */
    function withdrawShares(address vault, uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(vault != address(0), "Invalid vault");
        require(shares > 0, "Shares must be > 0");

        (uint256 trackedShares, uint256 depositedAssets) = VaultDepositsStorage.getDeposit(vault);
        require(trackedShares >= shares, "Insufficient tracked shares");

        // Calculate proportional assets to remove from tracking
        uint256 assetsToRemove = (depositedAssets * shares) / trackedShares;

        // Remove from tracking
        VaultDepositsStorage.removeDeposit(vault, shares, assetsToRemove);

        // Transfer shares to owner
        address owner = _portfolioFactory.ownerOf(address(this));
        IERC20(vault).safeTransfer(owner, shares);

        emit SharesWithdrawn(vault, shares, assetsToRemove, owner);
    }

    // ============ Yield Claiming ============

    /**
     * @dev Claim vault yield - redeems shares representing accumulated yield
     * Returns the underlying assets to this contract for further processing
     * @param vault The ERC4626 vault address
     * @return yieldAssets The amount of yield claimed (in underlying assets)
     */
    function claimVaultYield(address vault) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 yieldAssets) {
        require(vault != address(0), "Invalid vault");

        // Get deposit info
        (uint256 trackedShares, uint256 depositedAssets) = VaultDepositsStorage.getDeposit(vault);
        require(trackedShares > 0, "No shares deposited");

        // Calculate current asset value of tracked shares
        uint256 currentAssets = IERC4626(vault).convertToAssets(trackedShares);

        // Calculate yield (current value - original deposit value)
        require(currentAssets > depositedAssets, "No yield to harvest");

        // Calculate shares to redeem by finding excess shares beyond what's needed for original deposit
        // This avoids double rounding errors from: yieldAssets -> sharesToRedeem -> assetsReceived
        // Instead: we calculate how many shares are needed to cover depositedAssets, and redeem the rest
        uint256 sharesNeededForDeposit = IERC4626(vault).convertToShares(depositedAssets);
        uint256 sharesToRedeem = trackedShares - sharesNeededForDeposit;
        require(sharesToRedeem > 0, "Yield too small to harvest");

        // Redeem shares for underlying assets
        address vaultAsset = IERC4626(vault).asset();
        uint256 assetsReceived = IERC4626(vault).redeem(sharesToRedeem, address(this), address(this));

        // Update tracking - remove redeemed shares but keep original deposit tracking
        VaultDepositsStorage.removeDeposit(vault, sharesToRedeem, 0);

        emit VaultYieldClaimed(vault, assetsReceived, sharesToRedeem, vaultAsset, _portfolioFactory.ownerOf(address(this)));

        return assetsReceived;
    }

    // ============ View Functions ============

    /**
     * @dev Get the current yield available to harvest
     * @param vault The ERC4626 vault address
     * @return yieldAssets The yield in underlying assets (what you'll receive)
     * @return yieldShares The shares that would be redeemed for the yield
     */
    function getAvailableYield(address vault) external view returns (uint256 yieldAssets, uint256 yieldShares) {
        (uint256 trackedShares, uint256 depositedAssets) = VaultDepositsStorage.getDeposit(vault);
        if (trackedShares == 0) {
            return (0, 0);
        }

        uint256 currentAssets = IERC4626(vault).convertToAssets(trackedShares);
        if (currentAssets <= depositedAssets) {
            return (0, 0);
        }

        // Calculate excess shares beyond what's needed for original deposit
        // This matches the actual redemption calculation in claimVaultYield
        uint256 sharesNeededForDeposit = IERC4626(vault).convertToShares(depositedAssets);
        yieldShares = trackedShares - sharesNeededForDeposit;

        // Calculate actual assets that would be received from redeeming those shares
        yieldAssets = IERC4626(vault).convertToAssets(yieldShares);
    }

    /**
     * @dev Get deposit info for a vault
     * @param vault The ERC4626 vault address
     * @return shares Total tracked shares
     * @return depositedAssets Original asset value at deposit time
     * @return currentAssets Current asset value of shares
     */
    function getDepositInfo(address vault) external view returns (uint256 shares, uint256 depositedAssets, uint256 currentAssets) {
        (shares, depositedAssets) = VaultDepositsStorage.getDeposit(vault);
        if (shares > 0) {
            currentAssets = IERC4626(vault).convertToAssets(shares);
        }
    }
}
