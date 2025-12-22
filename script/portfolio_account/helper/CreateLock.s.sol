// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title CreateLock
 * @dev Helper script to create a voting escrow lock via PortfolioManager multicall
 * 
 * Portfolio address can be loaded from addresses.json (field: "portfolioaddress" or "portfolioAddress")
 * or passed as a parameter/environment variable.
 * 
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run(address,uint256,uint256)" <PORTFOLIO_ADDRESS> <AMOUNT> <LOCK_DURATION> --rpc-url $RPC_URL --broadcast
 * 2. From addresses.json + env vars: AMOUNT=1000000000000000000 LOCK_DURATION=31536000 forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $RPC_URL --broadcast
 * 
 * Example:
 * forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run(address,uint256,uint256)" 0x123... 1000000000000000000 31536000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract CreateLock is Script {
    using stdJson for string;

    /**
     * @dev Load PortfolioManager address from addresses.json or environment variable
     */
    function loadPortfolioManager() internal view returns (PortfolioManager) {
        address portfolioManagerAddr;
        
        // Try to read from addresses.json
        try vm.readFile(string.concat(vm.projectRoot(), "/addresses/addresses.json")) returns (string memory addressesJson) {
            portfolioManagerAddr = addressesJson.readAddress(".portfoliomanager");
        } catch {
            // Fall back to environment variable
            portfolioManagerAddr = vm.envAddress("PORTFOLIO_MANAGER");
        }
        
        require(portfolioManagerAddr != address(0), "PortfolioManager address not found. Set PORTFOLIO_MANAGER env var or allow file access with --fs addresses");
        return PortfolioManager(portfolioManagerAddr);
    }

    /**
     * @dev Get PortfolioFactory for aerodrome-usdc from PortfolioManager
     */
    function getAerodromeFactory(PortfolioManager portfolioManager) internal view returns (PortfolioFactory) {
        bytes32 salt = keccak256(abi.encodePacked("aerodrome-usdc"));
        address factoryAddress = portfolioManager.factoryBySalt(salt);
        require(factoryAddress != address(0), "Aerodrome factory not found");
        return PortfolioFactory(factoryAddress);
    }

    /**
     * @dev Get voting escrow address - hardcoded for Aerodrome on Base
     */
    function getVotingEscrow() internal pure returns (address) {
        return 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO on Base
    }

    /**
     * @dev Get or create portfolio address for an owner from the aerodrome-usdc factory
     */
    function getPortfolioForOwner(address owner) internal returns (address) {
        PortfolioManager portfolioManager = loadPortfolioManager();
        PortfolioFactory factory = getAerodromeFactory(portfolioManager);
        address portfolio = factory.portfolioOf(owner);
        
        // If portfolio doesn't exist, create it
        if (portfolio == address(0)) {
            portfolio = factory.createAccount(owner);
            console.log("Created new portfolio for owner:", owner);
            console.log("Portfolio address:", portfolio);
        }
        
        return portfolio;
    }

    /**
     * @dev Load PortfolioAddress from addresses.json (optional, returns address(0) if not found)
     * Note: This function does NOT create portfolios - only reads existing addresses
     */
    function loadPortfolioAddress() internal view returns (address) {
        // Try to read from addresses.json
        try vm.readFile(string.concat(vm.projectRoot(), "/addresses/addresses.json")) returns (string memory addressesJson) {
            // Try to read portfolioaddress (lowercase)
            if (addressesJson.keyExists(".portfolioaddress")) {
                return addressesJson.readAddress(".portfolioaddress");
            }
            
            // Try alternative field name (camelCase)
            if (addressesJson.keyExists(".portfolioAddress")) {
                return addressesJson.readAddress(".portfolioAddress");
            }
            
            // Note: We don't create portfolio here - that happens during broadcast
            // If owner is in JSON, we'll return 0 and let the broadcast block handle creation
        } catch {
            // File read failed, will fall back to env vars
        }
        
        return address(0);
    }

    /**
     * @dev Create a lock via PortfolioManager multicall
     * @param portfolioAddress The portfolio account address
     * @param amount The amount of tokens to lock (in wei)
     * @param lockDuration The lock duration in seconds
     * @param owner The owner address (for token approval)
     * @return tokenId The token ID of the created lock
     */
    function createLock(
        address portfolioAddress,
        uint256 amount,
        uint256 lockDuration,
        address owner
    ) internal returns (uint256 tokenId) {
        PortfolioManager portfolioManager = loadPortfolioManager();
        
        // Verify the facet is registered
        PortfolioFactory factory = getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingEscrowFacet.createLock.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingEscrowFacet.createLock not registered in FacetRegistry. Please deploy facets first.");
        
        // Get voting escrow and underlying token
        address votingEscrowAddr = getVotingEscrow();
        IVotingEscrow votingEscrow = IVotingEscrow(votingEscrowAddr);
        address tokenAddress = votingEscrow.token();
        IERC20 token = IERC20(tokenAddress);
        
        // Approve portfolio account to spend tokens from owner
        uint256 currentAllowance = token.allowance(owner, portfolioAddress);
        if (currentAllowance < amount) {
            // Use vm.broadcast to sign as the owner (we're already in broadcast mode)
            token.approve(portfolioAddress, type(uint256).max);
            console.log("Approved portfolio to spend tokens");
        }
        
        address[] memory portfolios = new address[](1);
        portfolios[0] = portfolioAddress;
        
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            amount
        );
        
        bytes[] memory results = portfolioManager.multicall(calldatas, portfolios);
        require(results.length > 0, "Multicall failed - no results");
        
        tokenId = abi.decode(results[0], (uint256));
        
        console.log("Lock created successfully!");
        console.log("Token ID:", tokenId);
        console.log("Amount:", amount);
        console.log("Lock Duration:", lockDuration);
        
        return tokenId;
    }

    /**
     * @dev Main run function for forge script execution
     * @param portfolioAddress The portfolio account address
     * @param amount The amount of tokens to lock (in wei)
     * @param lockDuration The lock duration in seconds
     */
    function run(
        address portfolioAddress,
        uint256 amount,
        uint256 lockDuration
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = getAddressFromPrivateKey(privateKey);
        vm.startBroadcast(privateKey);
        createLock(portfolioAddress, amount, lockDuration, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Get address from private key
     */
    function getAddressFromPrivateKey(uint256 pk) internal pure returns (address) {
        return vm.addr(pk);
    }

    /**
     * @dev Alternative run function that reads parameters from addresses.json and environment variables
     * Portfolio address is loaded from addresses.json if available, otherwise from PORTFOLIO_ADDRESS env var,
     * or from PRIVATE_KEY/OWNER env var using the aerodrome-usdc factory
     * Usage: PRIVATE_KEY=0x... AMOUNT=1000000000000000000 LOCK_DURATION=31536000 forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 lockDuration = 125193600;
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        // Get owner address from private key
        address owner = getAddressFromPrivateKey(privateKey);
        
        vm.startBroadcast(privateKey);
        
        // Get or create portfolio (must happen during broadcast)
        // Always use owner-based lookup when PRIVATE_KEY is available to ensure portfolio exists
        address portfolioAddress = getPortfolioForOwner(owner);
        
        // Only use PORTFOLIO_ADDRESS if explicitly provided and different from owner-based lookup
        try vm.envAddress("PORTFOLIO_ADDRESS") returns (address providedAddr) {
            if (providedAddr != address(0) && providedAddr != portfolioAddress) {
                // Validate that provided address is registered
                PortfolioManager portfolioManager = loadPortfolioManager();
                address factory = portfolioManager.portfolioToFactory(providedAddr);
                if (factory != address(0)) {
                    portfolioAddress = providedAddr;
                } else {
                    console.log("Warning: PORTFOLIO_ADDRESS not registered, using owner-based portfolio");
                }
            }
        } catch {
            // PORTFOLIO_ADDRESS not set, use owner-based portfolio
        }
        
        createLock(portfolioAddress, amount, lockDuration, owner);
        vm.stopBroadcast();
    }
}

//     AMOUNT=1000000000000000000    LOCK_DURATION=31536000    forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock      --sig "run()"      --rpc-url $BASE_RPC_URL      --broadcast

