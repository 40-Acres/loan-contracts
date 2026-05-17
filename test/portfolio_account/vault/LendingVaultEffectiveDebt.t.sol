// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {NoOpVault} from "../../../src/facets/account/vault/NoOpVault.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

/* ===========================================================================
 * H-001 — Unified ILendingPool debt readers
 *
 * The interface now requires both `getDebtBalance` and `getEffectiveDebtBalance`.
 * For implementations without a separate "effective" notion (LendingVault,
 * NoOpVault), the contract MUST return the same value from both readers for
 * any borrower at any state.
 *
 * These tests pin the parity invariant — if a future change introduces a
 * divergence (e.g. someone adds vault-side reward vesting to LendingVault but
 * forgets to update getEffectiveDebtBalance), the parity test will fail loudly.
 * ==========================================================================*/

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPortfolioFactory is IPortfolioFactory {
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

contract LendingVaultEffectiveDebtTest is Test {
    LendingVault internal vault;
    MockUSDC internal usdc;
    MockPortfolioFactory internal portfolioFactory;

    address internal vaultOwner = address(0xA1);
    address internal depositor = address(0xB1);
    address internal borrower = address(0xC1);

    uint256 internal constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 internal constant EPOCH_2 = 2 * WEEK;

    uint256 internal constant MAX_UTIL_BPS = 8000;
    uint256 internal constant ORIG_FEE_BPS = 50;

    function setUp() public {
        // Hardcoded absolute timestamp — see repo memory note on via-ir/vm.warp.
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();

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

        vm.label(address(vault), "LendingVault");
        vm.label(address(usdc), "USDC");
        vm.label(borrower, "Borrower");
    }

    function _seedAndBorrow(uint256 deposit, uint256 borrowAmt) internal {
        usdc.mint(depositor, deposit);
        vm.startPrank(depositor);
        usdc.approve(address(vault), deposit);
        vault.deposit(deposit, depositor);
        vm.stopPrank();

        vm.prank(borrower);
        vault.borrowFromPortfolio(borrowAmt);
    }

    function _repay(uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(vault), amount);
        vault.payFromPortfolio(amount, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // 1. Parity for fresh borrower: both readers return 0
    // -------------------------------------------------------------------------

    function test_zeroBorrower_bothReadersReturnZero() public view {
        assertEq(vault.getDebtBalance(borrower), 0, "fresh borrower: getDebtBalance == 0");
        assertEq(vault.getEffectiveDebtBalance(borrower), 0, "fresh borrower: getEffectiveDebtBalance == 0");
        assertEq(
            vault.getEffectiveDebtBalance(borrower),
            vault.getDebtBalance(borrower),
            "parity must hold even at zero"
        );
    }

    function test_unrelatedAddress_bothReadersReturnZero() public view {
        address randomEoa = address(0xDEADBEEF);
        assertEq(vault.getDebtBalance(randomEoa), 0, "random EOA: getDebtBalance == 0");
        assertEq(vault.getEffectiveDebtBalance(randomEoa), 0, "random EOA: getEffectiveDebtBalance == 0");
    }

    // -------------------------------------------------------------------------
    // 2. Parity after a single borrow
    // -------------------------------------------------------------------------

    function test_afterBorrow_parityHolds() public {
        _seedAndBorrow(1000e6, 400e6);

        uint256 debt = vault.getDebtBalance(borrower);
        // Debt should equal the full borrow amount (LendingVault tracks principal pre-fee deduction;
        // see borrowFromPortfolio: $.debtBalance[msg.sender] += amount)
        assertEq(debt, 400e6, "debt equals full borrowed principal");
        assertEq(
            vault.getEffectiveDebtBalance(borrower),
            debt,
            "getEffectiveDebtBalance must mirror getDebtBalance after borrow"
        );
    }

    // -------------------------------------------------------------------------
    // 3. Parity after partial repay
    // -------------------------------------------------------------------------

    function test_afterPartialRepay_parityHolds() public {
        _seedAndBorrow(1000e6, 400e6);
        _repay(150e6);

        uint256 debt = vault.getDebtBalance(borrower);
        assertEq(debt, 250e6, "debt reduced by 150 after partial repay");
        assertEq(
            vault.getEffectiveDebtBalance(borrower),
            debt,
            "parity must hold after partial repay"
        );
    }

    // -------------------------------------------------------------------------
    // 4. Parity after full repay
    // -------------------------------------------------------------------------

    function test_afterFullRepay_parityHolds_zero() public {
        _seedAndBorrow(1000e6, 400e6);
        // Repay exactly the outstanding principal
        _repay(400e6);

        assertEq(vault.getDebtBalance(borrower), 0, "debt cleared after full repay");
        assertEq(vault.getEffectiveDebtBalance(borrower), 0, "effective debt cleared after full repay");
    }

    function test_overRepay_doesNotGoNegative_andParityHolds() public {
        _seedAndBorrow(1000e6, 400e6);
        // Try to over-repay: payFromPortfolio caps repayment at outstanding debt
        _repay(1_000e6);

        assertEq(vault.getDebtBalance(borrower), 0, "debt clamped to 0 on over-repay");
        assertEq(vault.getEffectiveDebtBalance(borrower), 0, "effective also clamped to 0");
    }

    // -------------------------------------------------------------------------
    // 5. Parity is preserved across the full borrow → repay cycle
    // -------------------------------------------------------------------------

    function test_lifecycleParity() public {
        _seedAndBorrow(2000e6, 800e6);
        _checkParity("after borrow");

        _repay(100e6);
        _checkParity("after first partial repay");

        _repay(300e6);
        _checkParity("after second partial repay");

        _repay(400e6);
        _checkParity("after full repay");
    }

    function _checkParity(string memory tag) internal view {
        assertEq(
            vault.getEffectiveDebtBalance(borrower),
            vault.getDebtBalance(borrower),
            string.concat("parity violated: ", tag)
        );
    }

    // -------------------------------------------------------------------------
    // 6. Fuzz: parity holds for any borrow / repay sequence
    // -------------------------------------------------------------------------

    function testFuzz_parityHoldsForAnyState(uint256 deposit, uint256 borrowAmt, uint256 repayAmt) public {
        deposit = bound(deposit, 1_000e6, 100_000_000e6);
        // Stay below 80% utilization cap (and reserve some for origination fee headroom)
        borrowAmt = bound(borrowAmt, 1, (deposit * 70) / 100);
        repayAmt = bound(repayAmt, 0, borrowAmt * 2);

        _seedAndBorrow(deposit, borrowAmt);
        if (repayAmt > 0) {
            _repay(repayAmt);
        }

        uint256 d = vault.getDebtBalance(borrower);
        uint256 e = vault.getEffectiveDebtBalance(borrower);
        assertEq(e, d, "parity must always hold");
        // Sanity: debt <= original borrow
        assertLe(d, borrowAmt, "debt cannot exceed original borrow");
    }

    // -------------------------------------------------------------------------
    // 7. ILendingPool interface compatibility — both methods callable through interface
    //    (catches signature drift if interface is renamed without updating impl)
    // -------------------------------------------------------------------------

    function test_callableThroughILendingPoolInterface() public {
        _seedAndBorrow(1000e6, 200e6);
        ILendingPool pool = ILendingPool(address(vault));
        assertEq(pool.getDebtBalance(borrower), 200e6, "ILendingPool.getDebtBalance routes correctly");
        assertEq(pool.getEffectiveDebtBalance(borrower), 200e6, "ILendingPool.getEffectiveDebtBalance routes correctly");
    }
}

/* ===========================================================================
 * NoOpVault — H-001 stubs
 * ==========================================================================*/

contract NoOpVaultEffectiveDebtTest is Test {
    NoOpVault internal vault;
    address internal asset_ = address(0x1234);
    address internal factory_ = address(0xABCD);

    function setUp() public {
        vault = new NoOpVault(factory_, asset_);
    }

    function test_getDebtBalance_alwaysZero() public view {
        assertEq(vault.getDebtBalance(address(0)), 0, "zero address: 0");
        assertEq(vault.getDebtBalance(address(this)), 0, "self: 0");
        assertEq(vault.getDebtBalance(address(0xBEEF)), 0, "arbitrary: 0");
    }

    function test_getEffectiveDebtBalance_alwaysZero() public view {
        assertEq(vault.getEffectiveDebtBalance(address(0)), 0, "zero address: 0");
        assertEq(vault.getEffectiveDebtBalance(address(this)), 0, "self: 0");
        assertEq(vault.getEffectiveDebtBalance(address(0xBEEF)), 0, "arbitrary: 0");
    }

    function test_parityForArbitraryAddresses() public view {
        // The whole point of NoOpVault is that it can never accrue debt; both
        // readers must agree (both 0) for any caller.
        assertEq(
            vault.getEffectiveDebtBalance(address(0xCAFE)),
            vault.getDebtBalance(address(0xCAFE)),
            "NoOpVault parity"
        );
    }

    function testFuzz_alwaysZero(address who) public view {
        assertEq(vault.getDebtBalance(who), 0, "fuzz: getDebtBalance always 0");
        assertEq(vault.getEffectiveDebtBalance(who), 0, "fuzz: getEffectiveDebtBalance always 0");
    }

    function test_callableThroughILendingPoolInterface() public view {
        ILendingPool pool = ILendingPool(address(vault));
        assertEq(pool.getDebtBalance(address(0xBEEF)), 0);
        assertEq(pool.getEffectiveDebtBalance(address(0xBEEF)), 0);
    }
}
