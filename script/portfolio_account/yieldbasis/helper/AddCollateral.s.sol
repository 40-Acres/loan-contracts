// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {IYieldBasisVotingEscrow} from "../../../../src/interfaces/IYieldBasisVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../../utils/PortfolioHelperUtils.sol";

/**
 * @title AddCollateral (YieldBasis)
 * @dev Helper script to add veYB as collateral via PortfolioManager multicall
 *
 * This transfers an existing veYB NFT from the owner's wallet to the portfolio account
 * and registers it as collateral for borrowing.
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/yieldbasis/helper/AddCollateral.s.sol:AddCollateral --sig "run(uint256)" <TOKEN_ID> --rpc-url $ETH_RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 forge script script/portfolio_account/yieldbasis/helper/AddCollateral.s.sol:AddCollateral --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/yieldbasis/helper/AddCollateral.s.sol:AddCollateral --sig "run(uint256)" 12345 --rpc-url $ETH_RPC_URL --broadcast
 */
contract AddCollateral is Script {
    using stdJson for string;

    // YieldBasis Contract Addresses (Ethereum Mainnet)
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;

    /**
     * @dev Add veYB collateral via PortfolioManager multicall
     * @param tokenId The token ID of the veYB NFT to add as collateral
     * @param owner The owner address (for getting portfolio from factory)
     */
    function addCollateral(
        uint256 tokenId,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Get YieldBasis factory
        PortfolioFactory factory = PortfolioHelperUtils.getYieldBasisFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = BaseCollateralFacet.addCollateral.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "CollateralFacet.addCollateral not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        if (portfolioAddress == address(0)) {
            // Create portfolio if it doesn't exist
            portfolioAddress = factory.createAccount(owner);
            console.log("Created new portfolio:", portfolioAddress);
        }

        // Verify token ownership
        IYieldBasisVotingEscrow veYB = IYieldBasisVotingEscrow(VE_YB);
        address tokenOwner = veYB.ownerOf(tokenId);
        require(tokenOwner == owner || tokenOwner == portfolioAddress, "Token not owned by user or portfolio");

        // Approve portfolio to transfer the veYB NFT (if owned by user)
        if (tokenOwner == owner) {
            IERC721(VE_YB).approve(portfolioAddress, tokenId);
            console.log("Approved portfolio to transfer veYB NFT");
        }

        // Get lock info before adding
        IYieldBasisVotingEscrow.LockedBalance memory lockInfo = veYB.locked(tokenOwner);
        console.log("Token locked amount:", uint256(uint128(lockInfo.amount)));
        console.log("Token unlock time:", lockInfo.end);

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(selector, tokenId);

        portfolioManager.multicall(calldatas, factories);

        console.log("Collateral added successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);

        // Get total locked collateral
        uint256 totalCollateral = CollateralFacet(portfolioAddress).getTotalLockedCollateral();
        console.log("Total Locked Collateral:", totalCollateral);

        // Get max loan info
        (uint256 maxLoan, uint256 currentDebt) = CollateralFacet(portfolioAddress).getMaxLoan();
        console.log("Max Loan Amount:", maxLoan);
        console.log("Current Debt:", currentDebt);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The token ID of the veYB NFT to add as collateral
     */
    function run(uint256 tokenId) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        addCollateral(tokenId, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=12345 forge script script/portfolio_account/yieldbasis/helper/AddCollateral.s.sol:AddCollateral --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        addCollateral(tokenId, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=12345 forge script script/portfolio_account/yieldbasis/helper/AddCollateral.s.sol:AddCollateral --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
