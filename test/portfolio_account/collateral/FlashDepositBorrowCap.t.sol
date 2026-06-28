// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * FlashDepositBorrowCap: a same-block (flash) deposit must not inflate vault borrow capacity.
 * Pattern B (DynamicCollateralManager) reads borrowableTotalAssets() -> fixed. Pattern A
 * (CollateralManager / legacy Vault) is out of scope and stays flash-manipulable (documented
 * residual). Guard: a deposit observed the next block SHOULD raise the cap.
 */

import {Test} from "forge-std/Test.sol";

import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {DynamicCollateralManager} from "../../../src/facets/account/collateral/DynamicCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* ---------------------------------------------------------------------------
 *  Flash-depositable mock pool/vault.
 *
 *  Satisfies the ILendingPool + ILendingVault slice the managers read in
 *  getMaxLoan:
 *    - lendingAsset()    -> asset token
 *    - lendingVault()    -> address(this) (vault is the pool here)
 *    - activeAssets()    -> outstandingCapital (settable; the binding term)
 *    - getDebtBalance()  -> per-borrower debt (Pattern B current debt read)
 *    - asset()           -> asset token
 *    - totalAssets()     -> LIVE balanceOf(this) (Pattern B vault-supply read)
 *
 *  deposit(assets, receiver) pulls `assets` of the asset token into the vault,
 *  so BOTH the Pattern A read (IERC20(asset).balanceOf(vault)) and the
 *  Pattern B read (totalAssets() == balanceOf(this)) rise on a same-block
 *  deposit -- exactly the manipulable surface in production.
 * -------------------------------------------------------------------------*/
contract FlashVaultPool {
    MockERC20 public immutable assetToken;
    address public immutable portfolioFactory;
    uint256 public _activeAssets; // outstandingCapital
    mapping(address => uint256) public debtOf;

    // Same-block deposit tracking -- mirrors the real vaults' flash-borrow-cap guard.
    uint256 public lastDepositBlock;
    uint256 public sameBlockDepositedAssets;

    constructor(address asset_, address factory_) {
        assetToken = MockERC20(asset_);
        portfolioFactory = factory_;
    }

    // --- ILendingPool slice ---
    function lendingAsset() external view returns (address) { return address(assetToken); }
    function lendingVault() external view returns (address) { return address(this); }
    function activeAssets() external view returns (uint256) { return _activeAssets; }
    function getDebtBalance(address b) external view returns (uint256) { return debtOf[b]; }
    function getEffectiveDebtBalance(address b) external view returns (uint256) { return debtOf[b]; }
    function borrowFromPortfolio(uint256) external pure returns (uint256) { return 0; }
    function payFromPortfolio(uint256 amt, uint256) external pure returns (uint256) { return amt; }
    function depositRewards(uint256) external {}

    // --- ILendingVault / IERC4626 slice the managers touch ---
    function asset() external view returns (address) { return address(assetToken); }
    // totalAssets tracks live vault liquidity.
    function totalAssets() public view returns (uint256) { return assetToken.balanceOf(address(this)); }
    function decimals() external pure returns (uint8) { return 18; }

    // borrowableTotalAssets mirrors the real vaults: totalAssets() minus assets
    // deposited in the current block, so a same-block (flash) deposit cannot
    // inflate the vault-liquidity term that gates borrow capacity. Both managers
    // now read this view for the supply term.
    function borrowableTotalAssets() external view returns (uint256) {
        uint256 ta = totalAssets();
        if (lastDepositBlock != block.number) return ta;
        return ta > sameBlockDepositedAssets ? ta - sameBlockDepositedAssets : 0;
    }

    // ERC4626-style deposit: pull `assets` of the underlying into the vault and
    // record it as a same-block deposit so borrowableTotalAssets() excludes it
    // until the next block.
    function deposit(uint256 assets, address /*receiver*/) external returns (uint256 shares) {
        assetToken.transferFrom(msg.sender, address(this), assets);
        if (lastDepositBlock != block.number) {
            lastDepositBlock = block.number;
            sameBlockDepositedAssets = assets;
        } else {
            sameBlockDepositedAssets += assets;
        }
        return assets;
    }

    // --- setLoanContract validation ---
    function getPortfolioFactory() external view returns (address) { return portfolioFactory; }

    // --- test helpers ---
    function setActive(uint256 v) external { _activeAssets = v; }
}

/* ---------------------------------------------------------------------------
 *  Harness exposing each library's getMaxLoan, and seeding collateral/debt
 *  directly into the manager's ERC-7201 slot via raw sstore (mirrors the
 *  raw-slot probe style in YieldBasisUtilizationCap.t.sol). This avoids the
 *  VotingEscrow plumbing addLockedCollateral needs and isolates the supply
 *  math under test.
 *
 *  Storage layout (both libs share the same struct prefix):
 *    slot+0: mapping lockedCollaterals
 *    slot+1: mapping originTimestamps
 *    slot+2: totalLockedCollateral
 *  Pattern A (CollateralManager) additionally:
 *    slot+3: debt
 * -------------------------------------------------------------------------*/
contract FlashHarness {
    // Pattern A
    function getMaxLoanA(address cfg) external view returns (uint256, uint256) {
        return CollateralManager.getMaxLoan(cfg);
    }
    // Pattern B
    function getMaxLoanB(address cfg) external view returns (uint256, uint256) {
        return DynamicCollateralManager.getMaxLoan(cfg);
    }

    function seedCollateralA(uint256 amount) external {
        bytes32 slot = keccak256("storage.CollateralManager");
        assembly { sstore(add(slot, 2), amount) } // totalLockedCollateral
    }
    function seedCollateralB(uint256 amount) external {
        bytes32 slot = keccak256("storage.DynamicCollateralManager");
        assembly { sstore(add(slot, 2), amount) } // totalLockedCollateral
    }
}

contract FlashDepositBorrowCapTest is Test {
    FlashHarness internal h;
    FlashVaultPool internal pool;
    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    MockERC20 internal asset;

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal DEPOSITOR = address(0xD3905170);

    // via-ir caches block.number across vm.roll; use hardcoded absolute blocks.
    uint256 internal constant BLOCK_START = 1_000_000;

    // --- supply-math parameters (see file header for derivation) ---
    // maxLoanIgnoreSupply = veBalance * rewardsRate / 1e6 * multiplier / 1e12.
    // With rewardsRate=10000, multiplier=100, collateral=1e33:
    //   = 1e33 * 1e4 / 1e6 * 100 / 1e12 = 1e21 (= 1000e18, far above the 146e18 supply term).
    uint256 internal constant COLLATERAL = 1e33;
    uint256 internal constant OUTSTANDING = 70e18;   // outstandingCapital
    uint256 internal constant VAULT_START = 100e18;  // initial vault liquidity
    uint256 internal constant FLASH_DEPOSIT = 100e18;
    // cap = 8000 bps (LoanConfig default fallback).
    //
    // Pattern A (CollateralManager, OUT OF SCOPE / unfixed): supply =
    //   IERC20(asset).balanceOf(vault) + outstandingCapital (raw spot read, no
    //   same-block exclusion).
    //   BEFORE: vaultBalance=100e18, supply=170e18, maxUtil=136e18,
    //     available=136-70 = 66e18.
    //   AFTER deposit (+100e18, ANY block -- raw balanceOf rises immediately):
    //     vaultBalance=200e18, supply=270e18, maxUtil=216e18, available=146e18.
    //   The raw read means the same-block (flash) deposit inflates the cap to
    //   146e18 just like a settled one -- the accepted Pattern-A residual.
    uint256 internal constant EXPECTED_BEFORE_A = 66e18;
    uint256 internal constant EXPECTED_AFTER_FLASH_A = 146e18;
    //
    // Pattern B (DynamicCollateralManager): supply = vault.borrowableTotalAssets()
    //   (already counts outstanding), so outstanding is NOT added again.
    //   BEFORE: borrowable=100e18, maxUtil=80e18, available=80-70 = 10e18.
    //   AFTER settled deposit (+100e18, next block): borrowable=200e18,
    //     maxUtil=160e18, available=90e18.
    uint256 internal constant EXPECTED_BEFORE_B = 10e18;
    uint256 internal constant EXPECTED_AFTER_FLASH_B = 90e18;

    function setUp() public {
        vm.warp(1700000000);
        vm.roll(BLOCK_START);

        vm.startPrank(OWNER);
        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, ) = pm.deployFactory(keccak256("flash-deposit-cap-test"));
        factory = f;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        asset = new MockERC20("WETH18", "WETH18", 18);

        pool = new FlashVaultPool(address(asset), address(factory));
        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));

        // Generous collateral ceiling so the VAULT-AVAILABLE term is binding.
        loanConfig.setRewardsRate(10000);
        loanConfig.setMultiplier(100);
        // Leave maxUtilizationBps unset -> defaults to 8000.
        vm.stopPrank();

        h = new FlashHarness();
        h.seedCollateralA(COLLATERAL);
        h.seedCollateralB(COLLATERAL);

        // Stage initial vault liquidity and outstanding capital.
        asset.mint(address(pool), VAULT_START);
        pool.setActive(OUTSTANDING);

        // Fund + approve the flash depositor.
        asset.mint(DEPOSITOR, FLASH_DEPOSIT);
        vm.prank(DEPOSITOR);
        asset.approve(address(pool), type(uint256).max);

        vm.label(address(h), "FlashHarness");
        vm.label(address(pool), "FlashVaultPool");
    }

    /* ===================================================================
     * Sanity: the vault-available term is the binding constraint.
     * (If this assert ever fails the harness has drifted and the flash
     * tests below would be testing the wrong code path.)
     * =================================================================== */
    function test_sanity_vaultAvailableIsBinding_A() public view {
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = h.getMaxLoanA(address(cfg));
        assertEq(maxLoan, EXPECTED_BEFORE_A, "Pattern A: supply-capped maxLoan binds at 66e18");
        // (EXPECTED_BEFORE_A == 66e18: raw balanceOf+outstanding supply term.)
        assertGt(maxLoanIgnoreSupply, maxLoan, "Pattern A: collateral ceiling far above supply cap");
    }

    function test_sanity_vaultAvailableIsBinding_B() public view {
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = h.getMaxLoanB(address(cfg));
        assertEq(maxLoan, EXPECTED_BEFORE_B, "Pattern B: supply-capped maxLoan binds at 10e18");
        assertGt(maxLoanIgnoreSupply, maxLoan, "Pattern B: collateral ceiling far above supply cap");
    }

    /* ===================================================================
     * Pattern A (CollateralManager / legacy-Vault-backed): OUT OF SCOPE.
     *
     * Pattern-A / legacy-Vault.sol-backed markets are intentionally NOT
     * covered by the flash-deposit fix (per the Pattern-B-only decision).
     * CollateralManager.getMaxLoan still reads raw IERC20(asset).balanceOf(vault),
     * which has no same-block exclusion, so a same-block (flash) deposit DOES
     * inflate the borrow cap. This test documents that accepted residual: it
     * asserts the cap IS still inflatable. Protecting Pattern A would require
     * adding borrowableTotalAssets() to the legacy vaults it points at.
     * =================================================================== */
    function test_PatternA_sameBlockFlashDeposit_KNOWN_outOfScope_capStillInflatable() public {
        (uint256 maxLoanBefore,) = h.getMaxLoanA(address(cfg));

        // Same block: a third party flash-deposits into the vault.
        vm.prank(DEPOSITOR);
        pool.deposit(FLASH_DEPOSIT, DEPOSITOR);

        (uint256 maxLoanAfter,) = h.getMaxLoanA(address(cfg));

        assertEq(maxLoanBefore, EXPECTED_BEFORE_A, "pre-deposit cap is the supply bound");

        // ACCEPTED RESIDUAL: raw balanceOf read means the same-block deposit
        // inflates the cap. Pattern A is out of scope and stays flash-vulnerable.
        assertGt(maxLoanAfter, maxLoanBefore, "Pattern A (out of scope): same-block deposit STILL inflates cap");
        assertEq(maxLoanAfter, EXPECTED_AFTER_FLASH_A, "Pattern A residual cap == 146e18 (raw balanceOf inflated)");
    }

    /* ===================================================================
     * Pattern B (DynamicCollateralManager / DynamicFeesVault-backed):
     * same-block flash deposit must NOT raise the borrow cap.
     * FAILS on current code (after > before).
     * =================================================================== */
    function test_PatternB_sameBlockFlashDeposit_mustNotRaiseCap() public {
        (uint256 maxLoanBefore,) = h.getMaxLoanB(address(cfg));

        vm.prank(DEPOSITOR);
        pool.deposit(FLASH_DEPOSIT, DEPOSITOR);

        (uint256 maxLoanAfter,) = h.getMaxLoanB(address(cfg));

        assertEq(maxLoanBefore, EXPECTED_BEFORE_B, "pre-deposit cap is the supply bound");

        // POST-FIX expectation. On buggy code maxLoanAfter == 90e18 > 10e18, so this FAILS.
        assertEq(maxLoanAfter, maxLoanBefore, "same-block deposit must not raise borrow cap (Pattern B)");
    }

    /* ===================================================================
     * GUARD: next-block deposits SHOULD still raise the cap.
     * These PASS today and must keep passing after any fix -- they pin the
     * intended behavior so a fix does not over-correct by ignoring real,
     * settled deposits. Labeled clearly.
     * =================================================================== */
    function test_GUARD_PatternA_nextBlockDeposit_doesRaiseCap() public {
        (uint256 maxLoanBefore,) = h.getMaxLoanA(address(cfg));
        assertEq(maxLoanBefore, EXPECTED_BEFORE_A, "pre-deposit cap is the supply bound");

        // Deposit in block N.
        vm.prank(DEPOSITOR);
        pool.deposit(FLASH_DEPOSIT, DEPOSITOR);

        // Observe at block N+1 (hardcoded absolute block; via-ir caches block.number).
        // Pattern A reads raw balanceOf with no block tracking, so the deposit
        // raises the cap regardless of block -- a real deposit still lifts capacity.
        vm.roll(BLOCK_START + 1);

        (uint256 maxLoanAfter,) = h.getMaxLoanA(address(cfg));
        assertEq(maxLoanAfter, EXPECTED_AFTER_FLASH_A, "next-block deposit raises cap to 146e18 (Pattern A)");
        assertGt(maxLoanAfter, maxLoanBefore, "settled deposit must raise the cap (Pattern A guard)");
    }

    function test_GUARD_PatternB_nextBlockDeposit_doesRaiseCap() public {
        (uint256 maxLoanBefore,) = h.getMaxLoanB(address(cfg));
        assertEq(maxLoanBefore, EXPECTED_BEFORE_B, "pre-deposit cap is the supply bound");

        vm.prank(DEPOSITOR);
        pool.deposit(FLASH_DEPOSIT, DEPOSITOR);

        vm.roll(BLOCK_START + 1);

        (uint256 maxLoanAfter,) = h.getMaxLoanB(address(cfg));
        assertEq(maxLoanAfter, EXPECTED_AFTER_FLASH_B, "next-block deposit raises cap to 90e18 (Pattern B)");
        assertGt(maxLoanAfter, maxLoanBefore, "settled deposit must raise the cap (Pattern B guard)");
    }
}
