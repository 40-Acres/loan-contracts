// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IDynamicFeesVault {
    function totalAssets() external view returns (uint256);
    function totalLoanedAssets() external view returns (uint256);
    function getUtilizationPercent() external view returns (uint256);
    function getCurrentVaultRatioBps() external view returns (uint256);
    function getDebtBalance(address borrower) external view returns (uint256);
    function asset() external view returns (address);
    function paused() external view returns (bool);
}

/**
 * @title Health
 * @dev Helper script to display protocol health metrics and user account info
 *
 * Usage:
 * 1. Protocol-only: forge script script/portfolio_account/helper/Health.s.sol:Health --sig "run()" --rpc-url $RPC_URL
 * 2. With user address: forge script script/portfolio_account/helper/Health.s.sol:Health --sig "run(address)" <USER_ADDRESS> --rpc-url $RPC_URL
 * 3. From env vars: USER_ADDRESS=0x... forge script script/portfolio_account/helper/Health.s.sol:Health --sig "runWithEnv()" --rpc-url $RPC_URL
 *
 * Environment variables:
 * - FACTORY_SALT: Factory salt to use (defaults to "aerodrome-usdc")
 *
 * Example:
 * forge script script/portfolio_account/helper/Health.s.sol:Health --sig "run()" --rpc-url $BASE_RPC_URL
 * forge script script/portfolio_account/helper/Health.s.sol:Health --sig "run(address)" 0x1234... --rpc-url $BASE_RPC_URL
 */
contract Health is Script {

    function displayProtocolHealth(PortfolioFactory factory, address vault) internal view {
        console.log("");
        console.log("============================================");
        console.log("         PROTOCOL HEALTH METRICS");
        console.log("============================================");

        // Get config
        PortfolioAccountConfig config = PortfolioHelperUtils.getConfigFromFactory(factory);
        LoanConfig loanConfig = config.getLoanConfig();

        // Loan Config Parameters
        console.log("");
        console.log("--- Loan Configuration ---");
        console.log("Rewards Rate:        ", loanConfig.getRewardsRate());
        console.log("Multiplier:          ", loanConfig.getMultiplier());
        console.log("Lender Premium:      ", loanConfig.getLenderPremium());
        console.log("Treasury Fee:        ", loanConfig.getTreasuryFee());
        console.log("Zero Balance Fee:    ", loanConfig.getZeroBalanceFee());

        // Vault Metrics
        console.log("");
        console.log("--- Vault Metrics ---");
        console.log("Vault Address:       ", vault);

        IDynamicFeesVault dynamicVault = IDynamicFeesVault(vault);
        address asset = dynamicVault.asset();

        uint256 vaultTotalAssets = dynamicVault.totalAssets();
        uint256 vaultBalance = IERC20(asset).balanceOf(vault);
        uint256 totalLoanedAssets = dynamicVault.totalLoanedAssets();
        uint256 utilizationPercent = dynamicVault.getUtilizationPercent();
        uint256 vaultRatioBps = dynamicVault.getCurrentVaultRatioBps();
        bool isPaused = dynamicVault.paused();

        console.log("Asset Address:       ", asset);
        console.log("Vault Total Assets:  ", vaultTotalAssets);
        console.log("Vault Balance:       ", vaultBalance);
        console.log("Total Loaned Assets: ", totalLoanedAssets);
        console.log("Utilization (bps):   ", utilizationPercent);
        console.log("Vault Fee Ratio (bps):", vaultRatioBps);
        console.log("Paused:              ", isPaused ? "YES" : "NO");

        // Calculate available to borrow (80% max utilization)
        uint256 maxUtilization = (vaultTotalAssets * 8000) / 10000;
        uint256 availableToBorrow = totalLoanedAssets >= maxUtilization ? 0 : maxUtilization - totalLoanedAssets;
        console.log("Available to Borrow: ", availableToBorrow);
    }

    function displayUserHealth(PortfolioFactory factory, address vault, address user) internal view {
        console.log("");
        console.log("============================================");
        console.log("         USER ACCOUNT HEALTH");
        console.log("============================================");
        console.log("User Address:        ", user);

        // Get portfolio address
        address portfolioAddress = factory.portfolioOf(user);

        if (portfolioAddress == address(0)) {
            console.log("Portfolio:           NOT CREATED");
            console.log("");
            console.log("User has no portfolio account yet.");
            return;
        }

        console.log("Portfolio Address:   ", portfolioAddress);
        console.log("");
        console.log("--- Collateral & Debt ---");

        CollateralFacet collateralFacet = CollateralFacet(portfolioAddress);

        uint256 totalLockedCollateral = collateralFacet.getTotalLockedCollateral();
        uint256 totalDebt = collateralFacet.getTotalDebt();
        uint256 unpaidFees = collateralFacet.getUnpaidFees();
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = collateralFacet.getMaxLoan();

        console.log("Total Collateral:    ", totalLockedCollateral);
        console.log("Total Debt:          ", totalDebt);
        console.log("Unpaid Fees:         ", unpaidFees);
        console.log("Max Loan Available:  ", maxLoan);
        console.log("Max Loan (no supply):", maxLoanIgnoreSupply);

        // Calculate health factor (how much of max loan is used)
        if (maxLoanIgnoreSupply > 0) {
            uint256 healthFactor = ((maxLoanIgnoreSupply - totalDebt) * 10000) / maxLoanIgnoreSupply;
            console.log("Health Factor (bps): ", healthFactor);
        } else {
            console.log("Health Factor:       N/A (no collateral)");
        }

        // Check vault debt balance for this portfolio
        IDynamicFeesVault dynamicVault = IDynamicFeesVault(vault);
        uint256 vaultDebtBalance = dynamicVault.getDebtBalance(portfolioAddress);
        console.log("Vault Debt Balance:  ", vaultDebtBalance);

        // Check collateral requirements
        bool collateralOk = collateralFacet.enforceCollateralRequirements();
        console.log("Collateral OK:       ", collateralOk ? "YES" : "NO");
    }

    /**
     * @dev Display protocol health only
     */
    function run() external view {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        address vault = PortfolioHelperUtils.getVaultFromFactory(vm, factory);

        displayProtocolHealth(factory, vault);

        console.log("");
        console.log("============================================");
        console.log("Tip: Pass an address to see user health:");
        console.log("forge script ... --sig \"run(address)\" 0x...");
        console.log("============================================");
    }

    /**
     * @dev Display protocol health and user account health
     * @param user The user address to check
     */
    function run(address user) external view {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        address vault = PortfolioHelperUtils.getVaultFromFactory(vm, factory);

        displayProtocolHealth(factory, vault);
        displayUserHealth(factory, vault, user);
    }

    /**
     * @dev Display health using USER_ADDRESS from environment
     */
    function runWithEnv() external view {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        address vault = PortfolioHelperUtils.getVaultFromFactory(vm, factory);

        displayProtocolHealth(factory, vault);

        // Try to get user address from env
        try vm.envAddress("USER_ADDRESS") returns (address user) {
            displayUserHealth(factory, vault, user);
        } catch {
            console.log("");
            console.log("No USER_ADDRESS provided in environment.");
        }
    }
}

// Example usage:
// Protocol only:
// FACTORY_SALT="aerodrome-usdc-dynamic-fees" forge script script/portfolio_account/helper/Health.s.sol:Health --sig "run()" --rpc-url $BASE_RPC_URL

// With user address:
// FACTORY_SALT="aerodrome-usdc-dynamic-fees" forge script script/portfolio_account/helper/Health.s.sol:Health --sig "run(address)" 0x1234... --rpc-url $BASE_RPC_URL

// With env var:
// FACTORY_SALT="aerodrome-usdc-dynamic-fees" USER_ADDRESS=0x1234... forge script script/portfolio_account/helper/Health.s.sol:Health --sig "runWithEnv()" --rpc-url $BASE_RPC_URL
