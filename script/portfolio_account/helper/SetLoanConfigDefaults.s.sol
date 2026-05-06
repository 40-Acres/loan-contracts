// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {ILoanConfig} from "../../../src/facets/account/config/ILoanConfig.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title SetLoanConfigDefaults
 * @dev Helper script to set rewardsRate and multiplier on LoanConfig to default values
 *
 * Default values:
 * - rewardsRate: 2850
 * - multiplier: 52
 * - ltv: 7000 (70% in bps)
 *
 * NOTE: This script must be run by the LoanConfig owner (typically the deployer)
 *
 * Usage (requires FORTY_ACRES_DEPLOYER env var):
 * 1. Default values: forge script script/portfolio_account/helper/SetLoanConfigDefaults.s.sol:SetLoanConfigDefaults --rpc-url $RPC_URL --broadcast
 * 2. Custom values: forge script script/portfolio_account/helper/SetLoanConfigDefaults.s.sol:SetLoanConfigDefaults --sig "run(uint256,uint256,uint256)" <REWARDS_RATE> <MULTIPLIER> <LTV> --rpc-url $RPC_URL --broadcast
 * 3. From env vars: REWARDS_RATE=2850 MULTIPLIER=52 LTV=7000 forge script script/portfolio_account/helper/SetLoanConfigDefaults.s.sol:SetLoanConfigDefaults --sig "runFromEnv()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * FACTORY_SALT=aerodrome-usdc-dynamic-fees forge script script/portfolio_account/helper/SetLoanConfigDefaults.s.sol:SetLoanConfigDefaults --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetLoanConfigDefaults is Script {
    using stdJson for string;

    uint256 public constant DEFAULT_REWARDS_RATE = 2850;
    uint256 public constant DEFAULT_MULTIPLIER = 52;
    uint256 public constant DEFAULT_LTV = 7000;
    uint256 public constant DEFAULT_TREASURY_FEE = 500;
    uint256 public constant DEFAULT_ZERO_BALANCE_FEE = 100;

    /**
     * @dev Set rewardsRate, multiplier, and ltv on LoanConfig.
     *      Cash-flow markets read rewardsRate + multiplier; like-to-like markets read ltv.
     * @param rewardsRate The rewards rate to set
     * @param multiplier The cash-flow multiplier (used by veNFT/rewards-rate markets)
     * @param ltv The loan-to-value ratio in bps (e.g., 7000 = 70%; used by like-to-like markets)
     */
    function setLoanConfigValues(uint256 rewardsRate, uint256 multiplier, uint256 ltv) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);

        // Get LoanConfig from PortfolioFactoryConfig
        ILoanConfig loanConfig = PortfolioHelperUtils.getConfigFromFactory(factory).getLoanConfig();
        require(address(loanConfig) != address(0), "LoanConfig not set in PortfolioFactoryConfig");

        // Set the values
        loanConfig.setRewardsRate(rewardsRate);
        loanConfig.setMultiplier(multiplier);
        loanConfig.setLtv(ltv);
        loanConfig.setTreasuryFee(DEFAULT_TREASURY_FEE);
        loanConfig.setZeroBalanceFee(DEFAULT_ZERO_BALANCE_FEE);

        console.log("LoanConfig values set successfully!");
        console.log("LoanConfig Address:", address(loanConfig));
        console.log("Rewards Rate:", rewardsRate);
        console.log("Multiplier:", multiplier);
        console.log("LTV (bps):", ltv);
        console.log("Treasury Fee:", DEFAULT_TREASURY_FEE);
        console.log("Zero Balance Fee:", DEFAULT_ZERO_BALANCE_FEE);
    }

    /**
     * @dev Main run function - sets default values (rewardsRate=2850, multiplier=52, ltv=7000)
     */
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        setLoanConfigValues(DEFAULT_REWARDS_RATE, DEFAULT_MULTIPLIER, DEFAULT_LTV);
        vm.stopBroadcast();
    }

    /**
     * @dev Run with custom values
     * @param rewardsRate The rewards rate to set
     * @param multiplier The cash-flow multiplier
     * @param ltv The loan-to-value ratio in bps
     */
    function run(uint256 rewardsRate, uint256 multiplier, uint256 ltv) external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        setLoanConfigValues(rewardsRate, multiplier, ltv);
        vm.stopBroadcast();
    }

    /**
     * @dev Run using environment variables for custom values
     * Usage: FORTY_ACRES_DEPLOYER=0x... REWARDS_RATE=2850 MULTIPLIER=52 LTV=7000 forge script ...
     */
    function runFromEnv() external {
        uint256 rewardsRate = vm.envOr("REWARDS_RATE", DEFAULT_REWARDS_RATE);
        uint256 multiplier = vm.envOr("MULTIPLIER", DEFAULT_MULTIPLIER);
        uint256 ltv = vm.envOr("LTV", DEFAULT_LTV);

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        setLoanConfigValues(rewardsRate, multiplier, ltv);
        vm.stopBroadcast();
    }
}

// Example usage:
// FACTORY_SALT=aerodrome-usdc-dynamic-fees forge script script/portfolio_account/helper/SetLoanConfigDefaults.s.sol:SetLoanConfigDefaults --rpc-url $BASE_RPC_URL --broadcast
