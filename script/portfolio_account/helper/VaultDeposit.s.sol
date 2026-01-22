// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

/**
 * @title VaultDeposit
 * @dev Helper script to deposit assets (USDC) into the vault and receive shares
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/VaultDeposit.s.sol:VaultDeposit --sig "run(uint256)" <AMOUNT> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: AMOUNT=1000000 forge script script/portfolio_account/helper/VaultDeposit.s.sol:VaultDeposit --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Environment variables:
 * - PRIVATE_KEY: Private key of the depositor (required)
 * - AMOUNT: Amount of assets to deposit in wei (required for run())
 * - VAULT_ADDRESS: Address of the vault to deposit into (required)
 *
 * Example:
 * VAULT_ADDRESS=0x... AMOUNT=1000000000 forge script script/portfolio_account/helper/VaultDeposit.s.sol:VaultDeposit --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
 */
contract VaultDeposit is Script {

    /**
     * @dev Deposit assets into the vault
     * @param amount The amount of assets to deposit (in wei, 6 decimals for USDC)
     * @param depositor The address depositing assets
     */
    function deposit(uint256 amount, address depositor) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);

        // Get vault and asset addresses from the factory's config
        address vaultAddress = PortfolioHelperUtils.getVaultFromFactory(vm, factory);
        address assetAddress = PortfolioHelperUtils.getDebtTokenFromFactory(vm, factory);

        console.log("Vault address:", vaultAddress);
        console.log("Asset address:", assetAddress);

        IERC4626 vault = IERC4626(vaultAddress);
        IERC20 asset = IERC20(assetAddress);

        // Check depositor's asset balance
        uint256 balance = asset.balanceOf(depositor);
        console.log("Depositor asset balance:", balance);
        require(balance >= amount, "Insufficient asset balance");

        // Preview shares to receive
        uint256 previewShares = vault.previewDeposit(amount);
        console.log("Expected shares to receive:", previewShares);

        // Check current allowance
        uint256 currentAllowance = asset.allowance(depositor, vaultAddress);
        if (currentAllowance < amount) {
            console.log("Approving vault to spend assets...");
            asset.approve(vaultAddress, type(uint256).max);
        }

        // Deposit
        uint256 sharesBefore = vault.balanceOf(depositor);
        uint256 shares = vault.deposit(amount, depositor);
        uint256 sharesAfter = vault.balanceOf(depositor);

        console.log("Deposit successful!");
        console.log("Amount deposited:", amount);
        console.log("Shares received:", shares);
        console.log("Shares balance before:", sharesBefore);
        console.log("Shares balance after:", sharesAfter);
    }

    /**
     * @dev Main run function for forge script execution
     * @param amount The amount of assets to deposit (in wei)
     */
    function run(uint256 amount) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address depositor = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        deposit(amount, depositor);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     */
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address depositor = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        deposit(amount, depositor);
        vm.stopBroadcast();
    }
}

// Example usage:
// AMOUNT=1000000000 forge script script/portfolio_account/helper/VaultDeposit.s.sol:VaultDeposit --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
// FACTORY_SALT="aerodrome-usdc-dynamic-fees" AMOUNT=1000000000 forge script script/portfolio_account/helper/VaultDeposit.s.sol:VaultDeposit --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
