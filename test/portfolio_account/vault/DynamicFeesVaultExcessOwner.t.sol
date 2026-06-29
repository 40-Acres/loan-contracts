// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {MockBlacklistableERC20} from "../../mocks/MockBlacklistableERC20.sol";

// ============ Issue Summary ============
// Excess borrower rewards (after debt is fully repaid) are routed to the portfolio
// ACCOUNT address inside _settleRewards via _transferOrEscrow($, user, ...), where
// `user` is the account (msg.sender / settleRewards arg). The account contract cannot
// call claimEscrow() nor forward received tokens, so excess is stranded.
//
// Intended behavior: excess should be routed to the portfolio OWNER, retrievable via
// IPortfolioFactory.ownerOf(account). Both the direct-transfer path and the
// escrow-on-failure path should target the owner.
//
// These tests use a factory mock that maps account -> a DISTINCT owner address so the
// account/owner split is observable. They FAIL on current source (excess lands on the
// account, escrow is keyed by the account) and pass once excess routes to the owner.

/**
 * @title MockPortfolioFactoryOwner
 * @notice Factory mock with a settable account -> owner mapping.
 */
contract MockPortfolioFactoryOwner is IPortfolioFactory {
    mapping(address => address) internal _owners;

    function setOwner(address portfolio, address owner) external {
        _owners[portfolio] = owner;
    }

    function isPortfolio(address _portfolio) external pure override returns (bool) {
        return _portfolio != address(0);
    }
    function ownerOf(address portfolio) external view override returns (address) {
        return _owners[portfolio];
    }
    function owners(address portfolio) external view override returns (address) {
        return _owners[portfolio];
    }
    function facetRegistry() external pure override returns (address) { return address(0); }
    function portfolioManager() external pure override returns (address) { return address(0); }
    function portfolios(address) external pure override returns (address) { return address(0); }
    function createAccount(address) external pure override returns (address) { return address(0); }
    function getRegistryVersion() external pure override returns (uint256) { return 0; }
    function portfolioOf(address) external pure override returns (address) { return address(0); }
    function getAllPortfolios() external pure override returns (address[] memory) { return new address[](0); }
    function getPortfoliosLength() external pure override returns (uint256) { return 0; }
    function getPortfolio(uint256) external pure override returns (address) { return address(0); }
}

/**
 * @title DynamicFeesVaultExcessOwnerTest
 * @notice Reproduces the excess-reward routing bug: excess must go to the portfolio owner.
 */
contract DynamicFeesVaultExcessOwnerTest is Test {
    DynamicFeesVault public vault;
    MockBlacklistableERC20 public usdc;
    MockPortfolioFactoryOwner public portfolioFactory;

    address public vaultOwner;
    address public account; // portfolio account address
    address public accountOwner; // distinct portfolio owner

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;

    function setUp() public {
        vm.warp(EPOCH_2);

        vaultOwner = address(0x1);
        account = address(0x2);
        accountOwner = address(0xABCD);

        usdc = new MockBlacklistableERC20("USD Coin", "USDC", 6);
        portfolioFactory = new MockPortfolioFactoryOwner();
        portfolioFactory.setOwner(account, accountOwner);

        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC", address(portfolioFactory), address(this), uint256(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(vaultOwner);
        vm.prank(vaultOwner);
        vault.acceptOwnership();

        // Seed vault with liquidity from test contract (lender)
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, address(this));
    }

    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        vault.borrowFromPortfolio(amount);
    }

    function _depositRewards(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.mint(user, amount);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    /// @notice Excess borrower rewards must be paid to the OWNER, not the account.
    function test_excessRewards_routedToOwner_notAccount() public {
        _borrow(account, 100e6);
        _depositRewards(account, 200e6);

        // After depositRewards the account's USDC balance is 0 (minted exactly, then pulled in).
        uint256 accountBalBefore = usdc.balanceOf(account);
        uint256 ownerBalBefore = usdc.balanceOf(accountOwner);

        vm.warp(EPOCH_3);
        vault.settleRewards(account);

        assertEq(vault.getDebtBalance(account), 0, "Debt should be fully paid");
        assertGt(usdc.balanceOf(accountOwner), ownerBalBefore, "Owner should receive excess USDC");
        assertEq(usdc.balanceOf(account), accountBalBefore, "Account should NOT receive excess USDC");
    }

    /// @notice When the owner is blacklisted, excess must be escrowed UNDER THE OWNER,
    ///         so the owner (not the account) can claim it.
    function test_excessRewards_escrowedUnderOwner_whenBlacklisted() public {
        _borrow(account, 100e6);
        _depositRewards(account, 300e6);

        // Blacklist the OWNER so the transfer-to-owner path fails into escrow.
        usdc.setBlacklisted(accountOwner, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(account);

        assertEq(vault.getDebtBalance(account), 0, "Debt should be cleared");

        // Un-blacklist owner and claim as the owner.
        usdc.setBlacklisted(accountOwner, false);
        uint256 ownerBalBefore = usdc.balanceOf(accountOwner);
        vm.prank(accountOwner);
        vault.claimEscrow();
        assertGt(usdc.balanceOf(accountOwner), ownerBalBefore, "Owner should claim escrowed excess");
    }
}
