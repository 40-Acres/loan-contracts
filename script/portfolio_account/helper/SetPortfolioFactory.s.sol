// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

interface ILoanWithPortfolioFactory {
    function setPortfolioFactory(address _newAccountStorage) external;
    function getPortfolioFactory() external view returns (address);
}

/**
 * @title SetPortfolioFactory
 * @dev Helper script to set the portfolio factory address on a legacy LoanV2 contract
 *      This is required for borrowFromPortfolio() to work on legacy (non-dynamic-fees) deployments.
 *
 * NOTE: This script must be run by the LoanV2 contract owner
 *
 * Usage:
 * FACTORY_SALT=aerodrome-usdc forge script script/portfolio_account/helper/SetPortfolioFactory.s.sol:SetPortfolioFactory --rpc-url $RPC_URL --broadcast
 */
contract SetPortfolioFactory is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("FORTY_ACRES_DEPLOYER");

        vm.startBroadcast(deployerKey);

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);

        // Get the loan contract from config
        address loanContract = PortfolioHelperUtils.getConfigFromFactory(factory).getLoanContract();
        require(loanContract != address(0), "LoanContract not set in PortfolioAccountConfig");

        // Get current portfolio factory setting
        address currentFactory = ILoanWithPortfolioFactory(loanContract).getPortfolioFactory();
        console.log("Loan contract:", loanContract);
        console.log("Current portfolio factory:", currentFactory);
        console.log("Target portfolio factory:", address(factory));

        if (currentFactory == address(factory)) {
            console.log("Portfolio factory already set correctly. No action needed.");
        } else {
            // Set the portfolio factory
            ILoanWithPortfolioFactory(loanContract).setPortfolioFactory(address(factory));
            console.log("Portfolio factory set successfully!");

            // Verify
            address newFactory = ILoanWithPortfolioFactory(loanContract).getPortfolioFactory();
            require(newFactory == address(factory), "Failed to set portfolio factory");
            console.log("Verified new portfolio factory:", newFactory);
        }

        vm.stopBroadcast();
    }
}
