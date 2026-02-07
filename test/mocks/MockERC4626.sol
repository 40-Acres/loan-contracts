// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockERC4626
 * @dev A mock ERC4626 vault for testing yield claiming functionality
 * Allows simulating yield by adding assets without minting shares
 */
contract MockERC4626 is ERC20, IERC4626 {
    using SafeERC20 for IERC20;

    IERC20 private immutable _asset;
    uint8 private immutable _decimals;

    constructor(
        address asset_,
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _asset = IERC20(asset_);
        _decimals = decimals_;
    }

    function decimals() public view virtual override(ERC20, IERC20Metadata) returns (uint8) {
        return _decimals;
    }

    function asset() public view virtual override returns (address) {
        return address(_asset);
    }

    function totalAssets() public view virtual override returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        uint256 total = totalAssets();
        return (supply == 0 || total == 0) ? assets : (assets * supply) / total;
    }

    function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    function maxDeposit(address) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view virtual override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        uint256 total = totalAssets();
        return (supply == 0 || total == 0) ? shares : (shares * total + supply - 1) / supply;
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        uint256 total = totalAssets();
        return (supply == 0 || total == 0) ? assets : (assets * supply + total - 1) / total;
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256 shares) {
        shares = previewDeposit(assets);
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public virtual override returns (uint256 assets) {
        assets = previewMint(shares);
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }
        _burn(owner, shares);
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }
        assets = previewRedeem(shares);
        _burn(owner, shares);
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ============ Test Helper Functions ============

    /**
     * @dev Simulate yield by adding assets to the vault without minting shares
     * This increases the value of existing shares
     */
    function simulateYield(uint256 yieldAmount) external {
        _asset.safeTransferFrom(msg.sender, address(this), yieldAmount);
    }

    /**
     * @dev Mint shares directly for testing (bypasses deposit)
     */
    function mintShares(address to, uint256 shares) external {
        _mint(to, shares);
    }
}
