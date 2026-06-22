// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {DynamicERC4626CollateralManager} from "./DynamicERC4626CollateralManager.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";

/**
 * @title DynamicERC4626ClaimingFacet
 * @dev Claims yield from ERC4626 vault shares used as collateral on a
 *      live-debt-read lending pool. Mirrors ERC4626ClaimingFacet; binds
 *      DynamicERC4626CollateralManager.
 */
contract DynamicERC4626ClaimingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IERC4626 public immutable _vault;
    uint8 public immutable _assetDecimals;

    error ReentrantCall();

    bytes32 private constant _LENDING_REENTRANCY_SLOT = keccak256("fortyacres.lending.reentrancy");

    modifier nonReentrant() {
        bytes32 slot = _LENDING_REENTRANCY_SLOT;
        uint256 status;
        assembly { status := sload(slot) }
        if (status == 2) revert ReentrantCall();
        assembly { sstore(slot, 2) }
        _;
        assembly { sstore(slot, 1) }
    }

    event VaultYieldClaimed(address indexed vault, uint256 yieldAssets, uint256 sharesRedeemed, address asset, address indexed owner);

    constructor(address portfolioFactory, address vault) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(vault != address(0), "Invalid vault");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _vault = IERC4626(vault);
        _assetDecimals = IERC20Metadata(IERC4626(vault).asset()).decimals();
    }

    // ============ Yield Claiming ============

    /**
     * @dev Claim vault yield -- redeems shares representing accumulated yield.
     *      Returns the underlying assets to this contract for further processing.
     *      See ERC4626ClaimingFacet for the slippage-floor rationale; logic is identical.
     */
    function claimVaultYield(uint256 minAssetsPerShare)
        external
        nonReentrant
        onlyAuthorizedCaller(_portfolioFactory)
        returns (uint256 yieldAssets)
    {
        require(minAssetsPerShare > 0, "Zero slippage floor");

        address vault = address(_vault);

        (uint256 trackedShares, uint256 depositedAssets, uint256 currentAssets) =
            DynamicERC4626CollateralManager.getCollateral(vault);

        require(trackedShares > 0, "No shares deposited");
        require(currentAssets > depositedAssets, "No yield to harvest");

        uint256 sharesNeededForDeposit = IERC4626(vault).previewWithdraw(depositedAssets);
        uint256 sharesToRedeem = trackedShares - sharesNeededForDeposit;
        require(sharesToRedeem > 0, "Yield too small to harvest");

        address vaultAsset = IERC4626(vault).asset();
        uint256 previewedAssets = IERC4626(vault).previewRedeem(sharesToRedeem);
        uint256 assetsReceived = IERC4626(vault).redeem(sharesToRedeem, address(this), address(this));

        uint256 minAssetsOut = (sharesToRedeem * minAssetsPerShare) / 1e18;
        require(assetsReceived >= minAssetsOut, "Slippage");

        require(assetsReceived * 100 >= previewedAssets * 85, "Slippage floor < 85%");

        address config = address(_portfolioFactory.portfolioFactoryConfig());
        DynamicERC4626CollateralManager.removeSharesForYield(config, vault, sharesToRedeem);

        DynamicERC4626CollateralManager.enforceCollateralRequirements(config, vault);

        emit VaultYieldClaimed(vault, assetsReceived, sharesToRedeem, vaultAsset, _portfolioFactory.ownerOf(address(this)));

        return assetsReceived;
    }

    // ============ View Functions ============

    function getAvailableYield() external view returns (uint256 yieldAssets, uint256 yieldShares) {
        address vault = address(_vault);

        (uint256 trackedShares, uint256 depositedAssets, uint256 currentAssets) =
            DynamicERC4626CollateralManager.getCollateral(vault);

        if (trackedShares == 0) {
            return (0, 0);
        }

        if (currentAssets <= depositedAssets) {
            return (0, 0);
        }

        uint256 sharesNeededForDeposit = IERC4626(vault).previewWithdraw(depositedAssets);
        if (trackedShares <= sharesNeededForDeposit) {
            return (0, 0);
        }
        yieldShares = trackedShares - sharesNeededForDeposit;

        yieldAssets = IERC4626(vault).convertToAssets(yieldShares);
    }

    function getDepositInfo() external view returns (
        address vault,
        uint256 shares,
        uint256 depositedAssets,
        uint256 currentAssets
    ) {
        vault = address(_vault);
        (shares, depositedAssets, currentAssets) = DynamicERC4626CollateralManager.getCollateral(vault);
    }
}
