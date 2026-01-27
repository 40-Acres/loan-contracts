// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

/**
 * @title VaultWithdraw
 * @dev Helper script to withdraw assets (USDC) from the vault by redeeming shares
 *
 * The vault address is automatically determined from the factory's PortfolioAccountConfig.
 * Uses FACTORY_SALT env var to select the factory (defaults to "aerodrome-usdc").
 *
 * Two modes of operation:
 * 1. Withdraw by assets: specify how much USDC you want to receive
 * 2. Redeem by shares: specify how many shares to redeem (use SHARES env var)
 *
 * Usage:
 * 1. Withdraw assets: AMOUNT=1000000 forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "run()" --rpc-url $RPC_URL --broadcast
 * 2. Redeem shares: SHARES=1000000 forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "runRedeem()" --rpc-url $RPC_URL --broadcast
 * 3. Redeem all shares: forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "runRedeemAll()" --rpc-url $RPC_URL --broadcast
 *
 * Environment variables:
 * - PRIVATE_KEY: Private key of the withdrawer (required)
 * - AMOUNT: Amount of assets to withdraw in wei (required for run())
 * - SHARES: Amount of shares to redeem (required for runRedeem())
 * - FACTORY_SALT: Factory salt to use (optional, defaults to "aerodrome-usdc")
 *
 * Example:
 * AMOUNT=1000000000 forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
 * FACTORY_SALT="aerodrome-usdc-dynamic-fees" SHARES=1000000 forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "runRedeem()" --rpc-url $BASE_RPC_URL --broadcast
 */
contract VaultWithdraw is Script {

    /**
     * @dev Withdraw assets from the vault
     * @param amount The amount of assets to withdraw (in wei, 6 decimals for USDC)
     * @param withdrawer The address withdrawing assets
     */
    function withdraw(uint256 amount, address withdrawer) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);

        // Get vault and asset addresses from the factory's config
        address vaultAddress = PortfolioHelperUtils.getVaultFromFactory(vm, factory);
        address assetAddress = PortfolioHelperUtils.getDebtTokenFromFactory(vm, factory);

        console.log("Vault address:", vaultAddress);
        console.log("Asset address:", assetAddress);

        IERC4626 vault = IERC4626(vaultAddress);
        IERC20 asset = IERC20(assetAddress);

        // Check withdrawer's share balance
        uint256 shareBalance = vault.balanceOf(withdrawer);
        console.log("Withdrawer share balance:", shareBalance);

        // Preview shares needed
        uint256 sharesNeeded = vault.previewWithdraw(amount);
        console.log("Shares needed for withdrawal:", sharesNeeded);
        require(shareBalance >= sharesNeeded, "Insufficient share balance");

        // Check max withdrawal
        uint256 maxWithdraw = vault.maxWithdraw(withdrawer);
        console.log("Max withdrawable assets:", maxWithdraw);
        require(amount <= maxWithdraw, "Amount exceeds max withdrawal");

        // Withdraw
        uint256 assetsBefore = asset.balanceOf(withdrawer);
        uint256 shares = vault.withdraw(amount, withdrawer, withdrawer);
        uint256 assetsAfter = asset.balanceOf(withdrawer);

        console.log("Withdrawal successful!");
        console.log("Assets withdrawn:", amount);
        console.log("Shares burned:", shares);
        console.log("Asset balance before:", assetsBefore);
        console.log("Asset balance after:", assetsAfter);
    }

    /**
     * @dev Redeem shares from the vault for assets
     * @param shares The amount of shares to redeem
     * @param withdrawer The address redeeming shares
     */
    function redeem(uint256 shares, address withdrawer) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);

        // Get vault and asset addresses from the factory's config
        address vaultAddress = PortfolioHelperUtils.getVaultFromFactory(vm, factory);
        address assetAddress = PortfolioHelperUtils.getDebtTokenFromFactory(vm, factory);

        console.log("Vault address:", vaultAddress);
        console.log("Asset address:", assetAddress);

        IERC4626 vault = IERC4626(vaultAddress);
        IERC20 asset = IERC20(assetAddress);

        // Check withdrawer's share balance
        uint256 shareBalance = vault.balanceOf(withdrawer);
        console.log("Withdrawer share balance:", shareBalance);
        require(shareBalance >= shares, "Insufficient share balance");

        // Preview assets to receive
        uint256 assetsToReceive = vault.previewRedeem(shares);
        console.log("Expected assets to receive:", assetsToReceive);

        // Redeem
        uint256 assetsBefore = asset.balanceOf(withdrawer);
        uint256 assets = vault.redeem(shares, withdrawer, withdrawer);
        uint256 assetsAfter = asset.balanceOf(withdrawer);

        console.log("Redemption successful!");
        console.log("Shares redeemed:", shares);
        console.log("Assets received:", assets);
        console.log("Asset balance before:", assetsBefore);
        console.log("Asset balance after:", assetsAfter);
    }

    /**
     * @dev Main run function - withdraw by asset amount
     * @param amount The amount of assets to withdraw (in wei)
     */
    function run(uint256 amount) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address withdrawer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        withdraw(amount, withdrawer);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads AMOUNT from environment variable
     */
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address withdrawer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        withdraw(amount, withdrawer);
        vm.stopBroadcast();
    }

    /**
     * @dev Run function to redeem by share amount
     */
    function runRedeem() external {
        uint256 shares = vm.envUint("SHARES");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address withdrawer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        redeem(shares, withdrawer);
        vm.stopBroadcast();
    }

    /**
     * @dev Run function to redeem all shares
     */
    function runRedeemAll() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address withdrawer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        address vaultAddress = PortfolioHelperUtils.getVaultFromFactory(vm, factory);

        uint256 shares = IERC4626(vaultAddress).balanceOf(withdrawer);
        require(shares > 0, "No shares to redeem");

        vm.startBroadcast(privateKey);
        redeem(shares, withdrawer);
        vm.stopBroadcast();
    }
}

// Example usage:
// AMOUNT=1000000000 forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
// SHARES=1000000 forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "runRedeem()" --rpc-url $BASE_RPC_URL --broadcast
// forge script script/portfolio_account/helper/VaultWithdraw.s.sol:VaultWithdraw --sig "runRedeemAll()" --rpc-url $BASE_RPC_URL --broadcast
