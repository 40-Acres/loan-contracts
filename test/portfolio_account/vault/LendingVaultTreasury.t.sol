// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/* ===========================================================================
 * LendingVault — unit tests for the new `treasury` storage field, its setter,
 * and the live fee-routing swap (origination fee on borrow + protocol fee on
 * pay) from owner() to getTreasury().
 *
 * Coverage:
 *   - setTreasury onlyOwner revert (NotOwner — vault uses its own modifier)
 *   - setTreasury rejects address(0) with InvalidTreasury
 *   - setTreasury emits TreasuryUpdated(oldT, newT) with exact args
 *     including the first-set transition from address(0)
 *   - getTreasury() falls back to owner() when storage is unset
 *   - Fallback proves itself in the HOT PATH: borrow + pay both deliver fees
 *     to owner() when treasury is unset
 *   - After setTreasury(T), origination fee on borrow lands at T (not owner)
 *   - After setTreasury(T), the protocol fee portion of payFromPortfolio
 *     (the feesToPay arg) lands at T (not owner)
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactoryLV is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) {
        return _portfolio != address(0);
    }
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

contract LendingVaultTreasuryTest is Test {
    LendingVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactoryLV public portfolioFactory;

    address public vaultOwner = address(0xA1);
    address public depositor = address(0xB1);
    address public borrower = address(0xC1);
    address public stranger = address(0xDEAD);
    address public treasuryA = address(0x7EA51);
    address public treasuryB = address(0x7EA52);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant ORIG_FEE_BPS = 50; // 0.5%
    uint256 constant SEED = 1_000_000e6;
    uint256 constant BORROW = 100_000e6;

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactoryLV();

        LendingVault impl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(usdc),
            address(portfolioFactory),
            vaultOwner,
            "Lending Vault",
            "lvUSDC",
            ORIG_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = LendingVault(address(proxy));

        // Seed liquidity so the vault can disburse a meaningful borrow.
        usdc.mint(depositor, SEED);
        vm.startPrank(depositor);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, depositor);
        vm.stopPrank();
        vm.roll(block.number + 1); // skip flash-deposit guard
    }

    // =====================================================================
    // setTreasury — access control + validation + event args
    // =====================================================================

    function test_setTreasury_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(LendingVault.NotOwner.selector);
        vault.setTreasury(treasuryA);
    }

    function test_setTreasury_revertsOnZeroAddress() public {
        vm.prank(vaultOwner);
        vm.expectRevert(LendingVault.InvalidTreasury.selector);
        vault.setTreasury(address(0));
    }

    /// @notice First-set transition: oldTreasury MUST be address(0), not owner().
    function test_setTreasury_emitsTreasuryUpdated_fromZeroOnFirstSet() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryUpdated(address(0), treasuryA);
        vm.prank(vaultOwner);
        vault.setTreasury(treasuryA);
    }

    function test_setTreasury_emitsTreasuryUpdated_onRotation() public {
        vm.prank(vaultOwner);
        vault.setTreasury(treasuryA);

        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryUpdated(treasuryA, treasuryB);
        vm.prank(vaultOwner);
        vault.setTreasury(treasuryB);
    }

    // =====================================================================
    // getTreasury view: fallback + explicit
    // =====================================================================

    function test_getTreasury_fallbackToOwner_whenUnset() public view {
        assertEq(vault.getTreasury(), vaultOwner, "fresh vault must fall back to owner()");
    }

    function test_getTreasury_returnsStoredValue_afterSet() public {
        vm.prank(vaultOwner);
        vault.setTreasury(treasuryA);
        assertEq(vault.getTreasury(), treasuryA);
    }

    // =====================================================================
    // Hot-path routing: origination fee on borrowFromPortfolio
    // =====================================================================

    /// @notice With treasury UNSET, origination fee MUST still arrive at owner()
    ///         via the fallback. Proves the fallback works in the actual
    ///         transfer path, not just in the public view.
    function test_borrow_originationFee_unsetTreasury_routesToOwner() public {
        uint256 ownerBefore = usdc.balanceOf(vaultOwner);
        uint256 expectedFee = (BORROW * ORIG_FEE_BPS) / 10000;
        assertGt(expectedFee, 0, "test config sanity: fee must be non-zero");

        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        assertEq(usdc.balanceOf(vaultOwner) - ownerBefore, expectedFee, "owner receives fee via fallback");
    }

    /// @notice After setTreasury(T), origination fee MUST land at T,
    ///         and owner() MUST receive nothing.
    function test_borrow_originationFee_setTreasury_routesToTreasuryNotOwner() public {
        vm.prank(vaultOwner);
        vault.setTreasury(treasuryA);

        uint256 ownerBefore = usdc.balanceOf(vaultOwner);
        uint256 treasuryBefore = usdc.balanceOf(treasuryA);
        uint256 expectedFee = (BORROW * ORIG_FEE_BPS) / 10000;

        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        assertEq(usdc.balanceOf(treasuryA) - treasuryBefore, expectedFee, "treasury receives the fee");
        assertEq(usdc.balanceOf(vaultOwner), ownerBefore, "owner must NOT receive the fee after setTreasury");
    }

    // =====================================================================
    // Hot-path routing: protocol fee (feesToPay) on payFromPortfolio
    // =====================================================================

    /// @notice Performs a borrow, then a partial payment with an explicit
    ///         feesToPay > 0. Validates owner-fallback in the pay flow.
    function test_payFromPortfolio_feesToPay_unsetTreasury_routesToOwner() public {
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        uint256 originationFee = (BORROW * ORIG_FEE_BPS) / 10000;
        // Borrower received BORROW - originationFee; we top them up so they can pay.
        uint256 toPay = 10_000e6;
        uint256 feesToPay = 500e6;
        usdc.mint(borrower, toPay);

        uint256 ownerBefore = usdc.balanceOf(vaultOwner);
        vm.startPrank(borrower);
        usdc.approve(address(vault), toPay);
        vault.payFromPortfolio(toPay, feesToPay);
        vm.stopPrank();

        assertEq(usdc.balanceOf(vaultOwner) - ownerBefore, feesToPay, "owner receives protocol fee via fallback");
        // Silence unused warning.
        originationFee;
    }

    function test_payFromPortfolio_feesToPay_setTreasury_routesToTreasuryNotOwner() public {
        vm.prank(vaultOwner);
        vault.setTreasury(treasuryA);

        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        uint256 toPay = 10_000e6;
        uint256 feesToPay = 500e6;
        usdc.mint(borrower, toPay);

        // Snapshot AFTER setTreasury+borrow so the borrow-time origination fee
        // (which we already confirmed routes to treasury) doesn't pollute the
        // delta we're measuring on the pay path.
        uint256 ownerBefore = usdc.balanceOf(vaultOwner);
        uint256 treasuryBefore = usdc.balanceOf(treasuryA);

        vm.startPrank(borrower);
        usdc.approve(address(vault), toPay);
        vault.payFromPortfolio(toPay, feesToPay);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasuryA) - treasuryBefore, feesToPay, "treasury receives pay-path fee");
        assertEq(usdc.balanceOf(vaultOwner), ownerBefore, "owner must NOT receive pay-path fee after setTreasury");
    }

    /// @notice Mid-loan treasury swap: borrow under fallback, then setTreasury,
    ///         then pay. The pay-path fee MUST follow the latest setting.
    ///         Pins the spec that the routing read is at-call-time, not cached.
    function test_payFromPortfolio_treasuryChange_appliesToSubsequentPay() public {
        // Borrow with treasury UNSET — origination fee goes to owner.
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        // Now rotate.
        vm.prank(vaultOwner);
        vault.setTreasury(treasuryA);

        uint256 toPay = 10_000e6;
        uint256 feesToPay = 500e6;
        usdc.mint(borrower, toPay);

        uint256 treasuryBefore = usdc.balanceOf(treasuryA);

        vm.startPrank(borrower);
        usdc.approve(address(vault), toPay);
        vault.payFromPortfolio(toPay, feesToPay);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasuryA) - treasuryBefore, feesToPay, "pay-path fee follows updated treasury");
    }
}
