// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ILendingPool} from "../../../../src/interfaces/ILendingPool.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMockVault {
    function asset() external view returns (address);
}

/// @notice Minimal lending pool for HydrexCollateralManager wiring tests.
///         Tracks a single per-borrower debt counter and exposes the few
///         selectors HydrexCollateralManager calls. Does NOT model real lending
///         economics -- borrows are recorded but no actual asset transfers
///         occur unless `transferOnBorrow` is set.
contract MockLendingPool is ILendingPool {
    address public immutable _lendingAsset;
    address public immutable _vault;
    address public immutable _factory;

    uint256 public _activeAssets;
    mapping(address => uint256) public debt;

    uint256 public originationFeeBps; // returned to caller from borrowFromPortfolio
    bool public transferOnBorrow;

    constructor(address lendingAsset_, address vault_, address factory_) {
        _lendingAsset = lendingAsset_;
        _vault = vault_;
        _factory = factory_;
    }

    function getPortfolioFactory() external view returns (address) { return _factory; }

    function setOriginationFeeBps(uint256 bps) external { originationFeeBps = bps; }
    function setTransferOnBorrow(bool b) external { transferOnBorrow = b; }
    function setActiveAssets(uint256 v) external { _activeAssets = v; }
    function setDebt(address borrower, uint256 v) external { debt[borrower] = v; }

    function borrowFromPortfolio(uint256 amount) external override returns (uint256 originationFee) {
        originationFee = (amount * originationFeeBps) / 10000;
        debt[msg.sender] += amount;
        _activeAssets += amount;
        if (transferOnBorrow) {
            IERC20(_lendingAsset).transfer(msg.sender, amount - originationFee);
        }
    }

    function payFromPortfolio(uint256 totalPayment, uint256 /*feesToPay*/) external override returns (uint256 actualPaid) {
        uint256 d = debt[msg.sender];
        actualPaid = totalPayment > d ? d : totalPayment;
        if (actualPaid > 0) {
            IERC20(_lendingAsset).transferFrom(msg.sender, address(this), actualPaid);
        }
        debt[msg.sender] -= actualPaid;
        if (_activeAssets >= actualPaid) _activeAssets -= actualPaid;
    }

    function lendingAsset() external view override returns (address) { return _lendingAsset; }
    function lendingVault() external view override returns (address) { return _vault; }
    function activeAssets() external view override returns (uint256) { return _activeAssets; }
    function depositRewards(uint256) external override {}
    function getDebtBalance(address borrower) external view override returns (uint256) { return debt[borrower]; }
    function getEffectiveDebtBalance(address borrower) external view override returns (uint256) { return debt[borrower]; }
}

/// @notice Minimal IERC4626-shaped vault holding an underlying asset balance
///         so that `IERC20(underlying).balanceOf(vault)` can be read by
///         HydrexCollateralManager.getMaxLoan.
contract MockVaultShell is IERC4626 {
    address public immutable _asset;
    string public override name = "vault";
    string public override symbol = "vlt";
    uint8 public override decimals = 18;

    constructor(address asset_) { _asset = asset_; }
    function asset() external view override returns (address) { return _asset; }
    function totalAssets() external view override returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }
    function convertToShares(uint256 a) external pure override returns (uint256) { return a; }
    function convertToAssets(uint256 s) external pure override returns (uint256) { return s; }
    function maxDeposit(address) external pure override returns (uint256) { return type(uint256).max; }
    function previewDeposit(uint256 a) external pure override returns (uint256) { return a; }
    function deposit(uint256 a, address) external pure override returns (uint256) { return a; }
    function maxMint(address) external pure override returns (uint256) { return type(uint256).max; }
    function previewMint(uint256 s) external pure override returns (uint256) { return s; }
    function mint(uint256 s, address) external pure override returns (uint256) { return s; }
    function maxWithdraw(address) external pure override returns (uint256) { return 0; }
    function previewWithdraw(uint256 a) external pure override returns (uint256) { return a; }
    function withdraw(uint256, address, address) external pure override returns (uint256) { return 0; }
    function maxRedeem(address) external pure override returns (uint256) { return 0; }
    function previewRedeem(uint256 s) external pure override returns (uint256) { return s; }
    function redeem(uint256, address, address) external pure override returns (uint256) { return 0; }
    function totalSupply() external pure override returns (uint256) { return 0; }
    function balanceOf(address) external pure override returns (uint256) { return 0; }
    function transfer(address, uint256) external pure override returns (bool) { return false; }
    function allowance(address, address) external pure override returns (uint256) { return 0; }
    function approve(address, uint256) external pure override returns (bool) { return false; }
    function transferFrom(address, address, uint256) external pure override returns (bool) { return false; }
}
