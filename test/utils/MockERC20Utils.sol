// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC20Utils
 * @dev Utility contract for creating and deploying mock ERC20 tokens in tests
 * Provides helpers to deploy mocks and overwrite existing addresses on the network
 * 
 * Usage in tests:
 * ```
 * import {MockERC20Utils} from "../utils/MockERC20Utils.sol";
 * 
 * contract MyTest is Test {
 *     using MockERC20Utils for address;
 *     
 *     function setUp() public {
 *         // Deploy a new mock token
 *         MockERC20 token = MockERC20Utils.deployMockERC20("Test Token", "TEST");
 *         
 *         // Or overwrite an existing address
 *         address existingToken = 0x1234...;
 *         MockERC20 mock = MockERC20Utils.deployAndOverwrite(
 *             existingToken,
 *             "Mock Token",
 *             "MOCK"
 *         );
 *         mock.mint(address(this), 1000e18);
 *     }
 * }
 * ```
 */
contract MockERC20Utils is Test {
    /**
     * @dev Deploy a mock ERC20 token with default parameters (18 decimals)
     * @param name Token name
     * @param symbol Token symbol
     * @return token The deployed MockERC20 contract
     */
    function deployMockERC20(string memory name, string memory symbol) internal returns (MockERC20 token) {
        return deployMockERC20(name, symbol, 18);
    }

    /**
     * @dev Deploy a mock ERC20 token with custom decimals
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Number of decimals
     * @return token The deployed MockERC20 contract
     */
    function deployMockERC20(string memory name, string memory symbol, uint8 decimals) internal returns (MockERC20 token) {
        token = new MockERC20(name, symbol, decimals);
    }

    /**
     * @dev Deploy a mock ERC20 and overwrite an existing address using vm.etch
     * This allows you to replace a real token contract with a mock for testing
     * @param targetAddress The address to overwrite
     * @param name Token name
     * @param symbol Token symbol
     * @return token The MockERC20 contract interface at the target address
     */
    function deployAndOverwrite(
        address targetAddress,
        string memory name,
        string memory symbol
    ) internal returns (MockERC20 token) {
        return deployAndOverwrite(targetAddress, name, symbol, 18);
    }

    /**
     * @dev Deploy a mock ERC20 and overwrite an existing address using vm.etch
     * This allows you to replace a real token contract with a mock for testing
     * @param targetAddress The address to overwrite
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Number of decimals
     * @return token The MockERC20 contract interface at the target address
     */
    function deployAndOverwrite(
        address targetAddress,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal returns (MockERC20 token) {
        // Deploy the mock contract
        MockERC20 mock = new MockERC20(name, symbol, decimals);
        
        // Get the bytecode of the deployed contract
        bytes memory code = address(mock).code;
        
        // Overwrite the target address with the mock contract code
        vm.etch(targetAddress, code);
        
        // Return the interface at the target address
        return MockERC20(targetAddress);
    }

    /**
     * @dev Mint tokens to an address using the mock token
     * @param token The mock token contract
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mintTo(MockERC20 token, address to, uint256 amount) internal {
        token.mint(to, amount);
    }

    /**
     * @dev Burn tokens from an address using the mock token
     * @param token The mock token contract
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(MockERC20 token, address from, uint256 amount) internal {
        token.burn(from, amount);
    }
}

