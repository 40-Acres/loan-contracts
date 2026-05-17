// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/* ===========================================================================
 * DynamicFeesVault — unit tests for the new `treasury` storage field, its
 * setter, and the live fee-routing swap in payFromPortfolio (feesToPay → T).
 *
 * NB: filename intentionally distinct from `DynamicFeesVaultTreasury.t.sol`
 *     which covers the unrelated `feeRecipient` (performance-fee share mint).
 *
 * Coverage:
 *   - setTreasury onlyOwner (OZ Ownable2Step) revert encoding
 *   - setTreasury rejects address(0)
 *   - TreasuryUpdated event args correct on first-set (oldT == 0) AND rotation
 *   - getTreasury() falls back to owner() when unset
 *   - payFromPortfolio: feesToPay routes to owner() when treasury unset
 *   - payFromPortfolio: feesToPay routes to T after setTreasury(T)
 *   - Mid-flight treasury swap applies to subsequent pay
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactoryDFV is IPortfolioFactory {
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

contract DynamicFeesVaultTreasuryAddressTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactoryDFV public pf;

    address public owner;
    address public stranger = address(0xDEAD);
    address public borrower = address(0x20);
    address public feeRecipient = address(0xFEE);
    address public treasuryA = address(0x7EA51);
    address public treasuryB = address(0x7EA52);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant SEED = 1_000_000e6;
    uint256 constant BORROW = 100_000e6;
    uint256 constant DEFAULT_FEE_BPS = 2500;

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        pf = new MockPortfolioFactoryDFV();

        // initialize() sets owner = msg.sender (this contract); we then
        // transferOwnership to a fixed `owner` and accept (Ownable2Step).
        owner = address(0x1);

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC", address(pf), feeRecipient, DEFAULT_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));
        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        // Seed liquidity so borrow can disburse and pay can use treasury.
        usdc.mint(address(this), SEED);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, address(this));
    }

    // =====================================================================
    // setTreasury: access control + validation + event args
    // =====================================================================

    function test_setTreasury_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vault.setTreasury(treasuryA);
    }

    function test_setTreasury_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(DynamicFeesVault.InvalidTreasury.selector);
        vault.setTreasury(address(0));
    }

    function test_setTreasury_emitsTreasuryUpdated_fromZeroOnFirstSet() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryUpdated(address(0), treasuryA);
        vm.prank(owner);
        vault.setTreasury(treasuryA);
    }

    function test_setTreasury_emitsTreasuryUpdated_onRotation() public {
        vm.prank(owner);
        vault.setTreasury(treasuryA);

        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryUpdated(treasuryA, treasuryB);
        vm.prank(owner);
        vault.setTreasury(treasuryB);
    }

    // =====================================================================
    // getTreasury view: fallback + explicit
    // =====================================================================

    function test_getTreasury_fallbackToOwner_whenUnset() public view {
        assertEq(vault.getTreasury(), owner, "unset must fall back to owner()");
    }

    function test_getTreasury_returnsStoredValue_afterSet() public {
        vm.prank(owner);
        vault.setTreasury(treasuryA);
        assertEq(vault.getTreasury(), treasuryA);
    }

    // =====================================================================
    // Hot-path routing: payFromPortfolio's feesToPay
    // =====================================================================

    function _borrowAndPay(uint256 feesToPay, uint256 toPay) internal {
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        usdc.mint(borrower, toPay);
        vm.startPrank(borrower);
        usdc.approve(address(vault), toPay);
        vault.payFromPortfolio(toPay, feesToPay);
        vm.stopPrank();
    }

    function test_payFromPortfolio_feesToPay_unsetTreasury_routesToOwner() public {
        uint256 toPay = 10_000e6;
        uint256 feesToPay = 500e6;

        uint256 ownerBefore = usdc.balanceOf(owner);
        _borrowAndPay(feesToPay, toPay);

        assertEq(usdc.balanceOf(owner) - ownerBefore, feesToPay, "owner receives pay-path fee via fallback");
    }

    function test_payFromPortfolio_feesToPay_setTreasury_routesToTreasuryNotOwner() public {
        vm.prank(owner);
        vault.setTreasury(treasuryA);

        uint256 toPay = 10_000e6;
        uint256 feesToPay = 500e6;

        uint256 ownerBefore = usdc.balanceOf(owner);
        uint256 treasuryBefore = usdc.balanceOf(treasuryA);
        _borrowAndPay(feesToPay, toPay);

        assertEq(usdc.balanceOf(treasuryA) - treasuryBefore, feesToPay, "treasury receives fee");
        assertEq(usdc.balanceOf(owner), ownerBefore, "owner must NOT receive fee after setTreasury");
    }

    /// @notice Treasury rotation after the borrow but before the pay must apply
    ///         to the pay-path fee — proves the getTreasury() read is at the
    ///         transfer site, not at borrow-time or cached.
    function test_payFromPortfolio_treasuryRotation_appliesToPay() public {
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        vm.prank(owner);
        vault.setTreasury(treasuryA);

        uint256 toPay = 10_000e6;
        uint256 feesToPay = 500e6;
        usdc.mint(borrower, toPay);

        uint256 treasuryBefore = usdc.balanceOf(treasuryA);
        vm.startPrank(borrower);
        usdc.approve(address(vault), toPay);
        vault.payFromPortfolio(toPay, feesToPay);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasuryA) - treasuryBefore, feesToPay, "rotated treasury receives the fee");
    }
}
