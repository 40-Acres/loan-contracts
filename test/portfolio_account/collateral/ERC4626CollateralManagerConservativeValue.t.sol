// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * ISSUE UNDER TEST -- Conservative collateral valuation
 * ==========================================================================
 *
 * ERC4626CollateralManager._resolveCollateralValue currently returns
 * IERC4626(vault).convertToAssets(shares) only. For vaults that charge an
 * exit fee (or otherwise have previewRedeem(s) < convertToAssets(s)), this
 * overstates net-realizable collateral and lets a borrower draw above the
 * value they could actually redeem.
 *
 * The intended (post-fix) behavior is to floor at the redemption value:
 *     value = min(convertToAssets(shares), previewRedeem(shares));
 *
 * The tests in this file pin specific numeric expectations against both the
 * no-fee and with-fee cases. On the current (broken) code, the with-fee
 * test must fail because the returned value still equals convertToAssets.
 * ==========================================================================
 */

import {Test} from "forge-std/Test.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockExitFeeERC4626} from "../../mocks/MockExitFeeERC4626.sol";

/**
 * @title ERC4626CollateralManagerHarness
 * @dev Thin wrapper exposing the parts of ERC4626CollateralManager that
 *      depend solely on the library's own storage and the vault. Sidesteps
 *      the full PortfolioFactory/LendingPool harness, since the bug under
 *      test lives entirely in _resolveCollateralValue's valuation math.
 *
 *      seedShares() writes data.shares at the library's ERC-7201-style slot
 *      so the harness behaves as if addCollateral had run, without the
 *      snapshot/sync side effects.
 */
contract ERC4626CollateralManagerHarness {
    bytes32 private constant STORAGE_POSITION = keccak256("storage.ERC4626CollateralManager");

    function seedShares(uint256 shares) external {
        bytes32 position = STORAGE_POSITION;
        ERC4626CollateralManager.ERC4626CollateralData storage data;
        assembly {
            data.slot := position
        }
        data.shares = shares;
    }

    function getTotalCollateralValue(address vault) external view returns (uint256) {
        return ERC4626CollateralManager.getTotalCollateralValue(vault);
    }

    function getCollateral(address vault)
        external
        view
        returns (uint256 shares, uint256 depositedAssetValue, uint256 currentAssetValue)
    {
        return ERC4626CollateralManager.getCollateral(vault);
    }
}

contract ERC4626CollateralManagerConservativeValueTest is Test {
    ERC4626CollateralManagerHarness internal _harness;
    MockERC20 internal _asset;
    MockExitFeeERC4626 internal _vault;

    // Use 6 decimals to mirror USDC-like accounting in the rest of the suite.
    uint256 internal constant SHARES_DEPOSITED = 1_000e6;
    uint256 internal constant ASSETS_BACKING = 1_000e6; // 1 share == 1 asset at setUp time

    function setUp() public {
        _harness = new ERC4626CollateralManagerHarness();
        _asset = new MockERC20("Mock USDC", "mUSDC", 6);
        _vault = new MockExitFeeERC4626(address(_asset), "Exit-Fee Vault", "EFV", 6);

        // Mint shares to the harness so the vault's totalSupply has weight
        // backing the convertToAssets math. We mirror with an equal asset
        // balance so 1 share converts to 1 asset.
        _vault.mintShares(address(_harness), SHARES_DEPOSITED);
        _asset.mint(address(_vault), ASSETS_BACKING);

        // Mark library storage as if the shares were registered as collateral.
        _harness.seedShares(SHARES_DEPOSITED);
    }

    /// @dev Sanity: with no exit fee, convertToAssets == previewRedeem and the
    ///      manager reports the full deposited asset value.
    function test_resolveCollateralValue_noExitFee_matchesConvertToAssets() public {
        _vault.setExitFeeBps(0);

        uint256 expected = _vault.convertToAssets(SHARES_DEPOSITED);
        assertEq(expected, ASSETS_BACKING, "sanity: 1:1 convertToAssets");
        assertEq(_vault.previewRedeem(SHARES_DEPOSITED), expected, "sanity: no haircut at 0 bps");

        uint256 reported = _harness.getTotalCollateralValue(address(_vault));
        assertEq(reported, ASSETS_BACKING, "no-fee path: reported value == convertToAssets");

        (, , uint256 currentAssetValue) = _harness.getCollateral(address(_vault));
        assertEq(currentAssetValue, ASSETS_BACKING, "no-fee path: getCollateral currentAssetValue");
    }

    /// @dev With a 5% exit fee, convertToAssets stays at 1_000e6 but the
    ///      shares can only redeem for 950e6. The manager must report the
    ///      redeemable floor, not the ideal value. This test fails on the
    ///      current code (returns 1_000e6) and passes after the min() fix.
    function test_resolveCollateralValue_withExitFee_floorsAtPreviewRedeem() public {
        _vault.setExitFeeBps(500); // 5%

        uint256 ideal = _vault.convertToAssets(SHARES_DEPOSITED);
        uint256 redeemable = _vault.previewRedeem(SHARES_DEPOSITED);
        assertEq(ideal, 1_000e6, "sanity: convertToAssets unchanged by exit fee");
        assertEq(redeemable, 950e6, "sanity: previewRedeem haircut at 500 bps");
        assertGt(ideal, redeemable, "sanity: ideal exceeds redeemable when exit fee applies");

        uint256 reported = _harness.getTotalCollateralValue(address(_vault));
        assertEq(
            reported,
            redeemable,
            "exit-fee path: reported value must floor at previewRedeem (net-realizable)"
        );

        (, , uint256 currentAssetValue) = _harness.getCollateral(address(_vault));
        assertEq(
            currentAssetValue,
            redeemable,
            "exit-fee path: getCollateral currentAssetValue must floor at previewRedeem"
        );
    }
}
