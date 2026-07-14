// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1000e6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactory is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) { return _portfolio != address(0); }
    function facetRegistry() external pure override returns (address) { return address(0); }
    function portfolioManager() external pure override returns (address) { return address(0); }
    function portfolios(address) external pure override returns (address) { return address(0); }
    function owners(address) external pure override returns (address) { return address(0); }
    function createAccount(address) external pure override returns (address) { return address(0); }
    function getRegistryVersion() external pure override returns (uint256) { return 0; }
    function ownerOf(address) external pure override returns (address) { return address(0); }
    function portfolioOf(address) external pure override returns (address) { return address(0); }
    function getAllPortfolios() external pure override returns (address[] memory) { return new address[](0); }
    function getPortfoliosLength() external pure override returns (uint256) { return 0; }
    function getPortfolio(uint256) external pure override returns (address) { return address(0); }
}

// 0% lender / 100% borrower credit.
contract ZeroLenderFeeCalculator is IFeeCalculator {
    function getVaultRatioBps(uint256) external pure override returns (uint256) { return 0; }
}

/// @notice Regression guard: totalAssets (NAV) is invariant across the global-vesting -> per-user-settlement window.
///         depositRewards pulls the full amount; the surplus over debt is refunded to the owner at settlement, and NAV
///         holds because that refunded excess was never lender assets (excluded by the conservative activeAssets()).
contract DynamicFeesVaultPreSettlementMisreportTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public owner = address(0x1);
    address public alice = address(0xA11CE); // small debt, over-deposits rewards
    address public bob = address(0xB0B);     // large debt, no reward stream

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;

    uint256 constant ALICE_DEBT = 10e6;
    uint256 constant BOB_DEBT = 100e6;
    uint256 constant ALICE_REWARDS = 100e6; // >> ALICE_DEBT; full amount pulled, surplus refunded at settlement

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();

        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC", address(portfolioFactory), address(this), uint256(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        // 100% borrower credit so the arithmetic matches the worked example exactly.
        ZeroLenderFeeCalculator calc = new ZeroLenderFeeCalculator();
        vm.prank(owner);
        vault.setFeeCalculator(address(calc));

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, address(this));

        // Borrows: Alice small, Bob large. Each address acts as its own portfolio.
        vm.prank(alice);
        vault.borrowFromPortfolio(ALICE_DEBT);
        vm.prank(bob);
        vault.borrowFromPortfolio(BOB_DEBT);

        // Alice's portfolio deposits rewards far exceeding her debt; the full amount is pulled and streamed.
        usdc.mint(alice, ALICE_REWARDS);
        vm.startPrank(alice);
        usdc.approve(address(vault), ALICE_REWARDS);
        vault.depositRewards(ALICE_REWARDS);
        vm.stopPrank();
    }

    /// @dev Advance to epoch end and persist global vesting WITHOUT per-user settlement.
    ///      sync() runs _processGlobalVesting (accrues globalBorrowerPending into storage)
    ///      but does not settle Alice's debt, so we observe the pre-settlement window.
    function _enterPreSettlementWindow() internal {
        vm.warp(EPOCH_3);
        vault.sync();
    }

    /// CLAIM: totalAssets() is invariant across the global-vesting -> settlement window; the surplus refunded to Alice at
    /// settlement was never lender assets, so NAV must not move (LPs neither gain nor lose from settlement timing).
    function test_totalAssets_invariant_acrossPreSettlementWindow() public {
        _enterPreSettlementWindow();

        uint256 pre = vault.totalAssets();

        vault.settleRewards(alice);
        vault.settleRewards(bob);

        uint256 post = vault.totalAssets();

        console.log("totalAssets pre :", pre);
        console.log("totalAssets post:", post);
        // Tolerance for floor-division dust in stream-rate vesting.
        assertApproxEqAbs(pre, post, 5, "totalAssets must be invariant across settlement");
    }
}
