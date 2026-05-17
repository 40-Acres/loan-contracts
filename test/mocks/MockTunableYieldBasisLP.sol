// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockTunableYieldBasisLP
 * @dev Tunable mock for the YieldBasis LP token used as collateral. Distinct
 *      from MockYieldBasisLP because it lets tests simulate the Curve-burn
 *      haircut: `withdraw` can deliver strictly less underlying than the fair
 *      pricePerShare-implied amount.
 *
 *      Knobs (defaults: pps=1e18, haircut=0 — behaves like MockYieldBasisLP):
 *        - setPricePerShare(uint256) — fair value per LP share (1e18-scaled).
 *        - setWithdrawHaircutBps(uint256) — bps of the fair amount that the
 *          burn does NOT deliver (e.g. 200 = 2% short).
 *
 *      Withdraw delivery formula (matches what real YB LPs do under Curve
 *      pool imbalance):
 *          fair      = shares * pps / 1e18
 *          delivered = fair * (10_000 - haircut) / 10_000
 *          require(delivered >= min_assets, "min_assets")
 *
 *      Underlying token is held BY THIS CONTRACT and transferred out on
 *      withdraw. Tests must seed the mock with underlying before exercising
 *      withdraw so transfers don't underflow.
 */
contract MockTunableYieldBasisLP is MockERC20 {
    IERC20 public immutable underlying;

    uint256 private _pricePerShare;
    uint256 public withdrawHaircutBps; // 0 = no haircut

    // ---- preview_withdraw override (for testing the conservative-mark min path) ----
    //
    // When set, `preview_withdraw` returns `_previewWithdrawForShares` instead of the
    // pricePerShare-derived value. Lets tests stage:
    //   - TRD-widened (override < fundamental): collateral mark must drop to override.
    //   - Inverted     (override > fundamental): collateral mark must stay at fundamental.
    // Set by calling `setPreviewWithdrawForShares(sharesArg, value)`. The mock only
    // honors the override for the exact `shares` argument it was registered against —
    // this matches the production use-case where the manager queries a single specific
    // share amount. For other `shares` queries the mock falls back to the haircut
    // formula above.
    uint256 private _previewWithdrawSharesKey;
    uint256 private _previewWithdrawValue;
    bool private _previewWithdrawOverrideActive;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        address underlying_
    ) MockERC20(name, symbol, decimals_) {
        require(underlying_ != address(0), "Underlying zero");
        underlying = IERC20(underlying_);
        _pricePerShare = 1e18;
    }

    // ============ Tunable Knobs ============

    function setPricePerShare(uint256 pps) external {
        _pricePerShare = pps;
    }

    function setWithdrawHaircutBps(uint256 bps) external {
        require(bps <= 10_000, "haircut > 100%");
        withdrawHaircutBps = bps;
    }

    /// @notice Register a one-shot preview_withdraw override. When `shares` is queried
    ///         next, preview_withdraw returns `value` exactly. Other share queries fall
    ///         back to the haircut formula. Allows tests to stage a withdrawable value
    ///         that is independent of pricePerShare (TRD-widened, inverted, or zero).
    function setPreviewWithdrawForShares(uint256 shares, uint256 value) external {
        _previewWithdrawSharesKey = shares;
        _previewWithdrawValue = value;
        _previewWithdrawOverrideActive = true;
    }

    /// @notice Clear any registered preview_withdraw override.
    function clearPreviewWithdrawOverride() external {
        _previewWithdrawOverrideActive = false;
        _previewWithdrawSharesKey = 0;
        _previewWithdrawValue = 0;
    }

    // ============ YB LP Surface ============

    function pricePerShare() external view returns (uint256) {
        return _pricePerShare;
    }

    /// @notice What `withdraw(shares, ...)` would actually deliver right now.
    function preview_withdraw(uint256 shares) external view returns (uint256) {
        if (_previewWithdrawOverrideActive && shares == _previewWithdrawSharesKey) {
            return _previewWithdrawValue;
        }
        uint256 fair = (shares * _pricePerShare) / 1e18;
        return (fair * (10_000 - withdrawHaircutBps)) / 10_000;
    }

    /// @notice Burn `shares` LP from msg.sender, deliver underlying to receiver.
    ///         Amount delivered is fair * (1 - haircutBps/10_000). Reverts if
    ///         delivered < min_assets — this is the Curve-style slippage check
    ///         the production code relies on.
    function withdraw(uint256 shares, uint256 min_assets, address receiver) external returns (uint256 assets) {
        uint256 fair = (shares * _pricePerShare) / 1e18;
        assets = (fair * (10_000 - withdrawHaircutBps)) / 10_000;
        require(assets >= min_assets, "min_assets");

        // Burn caller's LP. Real YB LPs do this directly — no allowance dance,
        // since the LP token *is* the burner.
        _burn(msg.sender, shares);

        if (assets > 0) {
            require(underlying.transfer(receiver, assets), "underlying transfer failed");
        }
    }
}
