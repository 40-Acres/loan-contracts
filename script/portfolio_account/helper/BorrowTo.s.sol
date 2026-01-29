// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title BorrowTo
 * @dev Helper script to borrow USDC to another 40acres portfolio via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * The destination portfolio must be owned by the same owner.
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/BorrowTo.s.sol:BorrowTo --sig "run(address,uint256)" <TO_PORTFOLIO> <AMOUNT> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TO_PORTFOLIO=0x... AMOUNT=1000000 forge script script/portfolio_account/helper/BorrowTo.s.sol:BorrowTo --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/BorrowTo.s.sol:BorrowTo --sig "run(address,uint256)" 0x1234... 1000000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract BorrowTo is Script {
    using stdJson for string;

    /**
     * @dev Borrow USDC to another portfolio via PortfolioManager multicall
     * @param to The destination portfolio address (must be owned by the same owner)
     * @param amount The amount of USDC to borrow (in wei, 6 decimals for USDC)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function borrowTo(
        address to,
        uint256 amount,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = LendingFacet.borrowTo.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "LendingFacet.borrowTo not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Check max loan available
        (uint256 maxLoan, ) = CollateralFacet(portfolioAddress).getMaxLoan();
        console.log("Max loan available:", maxLoan);
        require(amount <= maxLoan, "Requested amount exceeds max loan");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            to,
            amount
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("BorrowTo successful!");
        console.log("From Portfolio:", portfolioAddress);
        console.log("To Portfolio:", to);
        console.log("Amount borrowed:", amount);

        // Check updated debt
        uint256 totalDebt = CollateralFacet(portfolioAddress).getTotalDebt();
        console.log("Total debt after borrow:", totalDebt);
    }

    /**
     * @dev Main run function for forge script execution
     * @param to The destination portfolio address
     * @param amount The amount of USDC to borrow (in wei)
     */
    function run(
        address to,
        uint256 amount
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        borrowTo(to, amount, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TO_PORTFOLIO=0x... AMOUNT=1000000 forge script script/portfolio_account/helper/BorrowTo.s.sol:BorrowTo --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        address to = vm.envAddress("TO_PORTFOLIO");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        borrowTo(to, amount, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TO_PORTFOLIO=0x1234... AMOUNT=1000000 forge script script/portfolio_account/helper/BorrowTo.s.sol:BorrowTo --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
