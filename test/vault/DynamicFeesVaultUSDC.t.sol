// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../vault/DynamicFeesVault.sol";
import {DebtToken} from "../../vault/DebtToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../src/interfaces/IPortfolioFactory.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token with 6 decimals
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 10000000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockPortfolioFactory
 * @notice Simple mock portfolio factory that returns true for isPortfolio if address is not zero
 */
contract MockPortfolioFactory is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) {
        return _portfolio != address(0);
    }

    // Required by interface but not used in this mock
    function facetRegistry() external pure override returns (address) {
        return address(0);
    }

    function portfolioManager() external pure override returns (address) {
        return address(0);
    }

    function portfolios(address) external pure override returns (address) {
        return address(0);
    }

    function owners(address) external pure override returns (address) {
        return address(0);
    }

    function createAccount(address) external pure override returns (address) {
        return address(0);
    }

    function getRegistryVersion() external pure override returns (uint256) {
        return 0;
    }

    function ownerOf(address) external pure override returns (address) {
        return address(0);
    }

    function portfolioOf(address) external pure override returns (address) {
        return address(0);
    }

    function getAllPortfolios() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function getPortfoliosLength() external pure override returns (uint256) {
        return 0;
    }

    function getPortfolio(uint256) external pure override returns (address) {
        return address(0);
    }
}

/**
 * @title DynamicFeesVaultTest
 * @notice Test suite for DynamicFeesVault with USDC
 */
contract DynamicFeesVaultTest is Test {
    DynamicFeesVault public vault;
    DebtToken public debtToken;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;
    address public owner;
    address public user1;

    function setUp() public {
        owner = address(0x1);
        user1 = address(0x2);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy mock portfolio factory
        portfolioFactory = new MockPortfolioFactory();

        // Deploy vault implementation
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc),
            "USDC Vault",
            "vUSDC",
            address(portfolioFactory)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(proxy));

        // Get the debt token that was created in initialize()
        debtToken = vault.debtToken();

        // Transfer ownership
        vault.transferOwnership(owner);

        // Deposit assets into vault so it has funds to borrow from
        usdc.approve(address(vault), 10000000e6);
        vault.deposit(10000000e6, address(this));
    }


    function testBorrow() public {
        vm.startPrank(user1);
        vault.borrow(1000000);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 8000, "Utilization should be less than 80%");
    }
}
