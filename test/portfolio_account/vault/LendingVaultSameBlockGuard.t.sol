// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

/*
 * LendingVaultSameBlockGuard: covers the borrow-cap guard. borrowableTotalAssets()
 * excludes assets deposited this block (so a flash deposit can't inflate borrow capacity)
 * and includes them next block; depositRewards must not register as a same-block deposit.
 * (The #243 lender-side same-block withdraw guard was removed; deposit->withdraw same block
 * now succeeds, covered by one positive round-trip test.)
 */

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

contract LendingVaultSameBlockGuardTest is Test {
    LendingVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public vaultOwner = address(0xA1);
    address public victim     = address(0xB1);
    address public attacker   = address(0xB2);
    address public alice      = address(0xC1);
    address public bob        = address(0xC2);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;

    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant ORIG_FEE_BPS = 0; // keep math clean

    // Absolute base block. via-ir may cache block.number across vm.roll calls
    // within a function, so multi-roll tests use hardcoded absolute numbers
    // (BLOCK_START + N) rather than block.number + 1.
    uint256 constant BLOCK_START = 1000;

    function setUp() public {
        vm.warp(EPOCH_2);
        vm.roll(BLOCK_START);

        vm.label(vaultOwner, "VaultOwner");
        vm.label(victim, "Victim");
        vm.label(attacker, "Attacker");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

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
    }

    // ----------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------

    function _selfDeposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _selfMint(address user, uint256 shares) internal {
        uint256 assets = vault.previewMint(shares);
        usdc.mint(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.mint(shares, user);
        vm.stopPrank();
    }

    // ----------------------------------------------------------
    // Positive round-trip: same-block deposit -> withdraw now SUCCEEDS.
    // Locks in the post-#243-removal behavior (no lender-side same-block
    // guard). The depositor gets their assets back in the same block.
    // ----------------------------------------------------------

    function test_selfDeposit_sameBlockWithdraw_succeeds() public {
        _selfDeposit(alice, 1000e6);

        // Same block, no vm.roll: withdraw must succeed now that the #243
        // lender-side guard is gone.
        vm.prank(alice);
        vault.withdraw(400e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 400e6, "alice withdrew assets in the same block as deposit");

        // And maxWithdraw is no longer short-circuited to 0 in the deposit block.
        assertGt(vault.maxWithdraw(alice), 0, "maxWithdraw non-zero same block (guard removed)");

        // Redeem the remainder in the same block too.
        uint256 remaining = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(remaining, alice, alice);
        assertGt(assetsOut, 0, "alice redeemed remaining shares same block");
        assertEq(vault.balanceOf(alice), 0, "all shares redeemed same block");
    }

    function test_selfMint_sameBlockRedeem_succeeds() public {
        _selfMint(alice, 1000e6); // 1000 shares
        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0, "alice minted shares");

        // Same block redeem now succeeds.
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertGt(assetsOut, 0, "alice redeemed minted shares same block");
        assertEq(usdc.balanceOf(alice), assetsOut, "alice received assets from same-block redeem");
    }

    // ----------------------------------------------------------
    // borrowableTotalAssets(): direct view tests against the
    // REAL LendingVault. This is the supply term the borrow-cap
    // managers read; it must exclude assets deposited THIS block
    // so a same-block (flash) deposit cannot inflate borrow cap,
    // yet include them once the block advances.
    //
    // via-ir caches block.number across vm.roll within a function;
    // use hardcoded absolute block numbers (BLOCK_START + N).
    // ----------------------------------------------------------

    function test_borrowableTotalAssets_excludesSameBlockDeposit() public {
        // Pre-deposit baseline at BLOCK_START.
        uint256 taBefore = vault.totalAssets();

        _selfDeposit(alice, 1000e6);

        // Same block: totalAssets rose by the deposit, but borrowableTotalAssets
        // must exclude it -- equal to the pre-deposit value.
        assertEq(vault.totalAssets(), taBefore + 1000e6, "totalAssets includes the deposit");
        assertEq(
            vault.borrowableTotalAssets(),
            vault.totalAssets() - 1000e6,
            "borrowableTotalAssets excludes the same-block deposit"
        );
        assertEq(vault.borrowableTotalAssets(), taBefore, "borrowable equals pre-deposit value");
    }

    function test_borrowableTotalAssets_includesDepositNextBlock() public {
        _selfDeposit(alice, 1000e6);

        // Next block: the deposit is no longer same-block, so it counts.
        vm.roll(BLOCK_START + 1);

        assertEq(
            vault.borrowableTotalAssets(),
            vault.totalAssets(),
            "next block: borrowableTotalAssets equals totalAssets"
        );
        assertEq(vault.borrowableTotalAssets(), 1000e6, "deposit fully counted next block");
    }

    function test_borrowableTotalAssets_multipleSameBlockDepositsAllExcluded() public {
        uint256 taBefore = vault.totalAssets();

        // Three deposits from different accounts, all in BLOCK_START.
        _selfDeposit(alice, 1000e6);
        _selfDeposit(bob, 500e6);
        _selfDeposit(victim, 250e6);

        uint256 totalDeposited = 1000e6 + 500e6 + 250e6;
        assertEq(vault.totalAssets(), taBefore + totalDeposited, "totalAssets includes all three");
        // All three accumulate into sameBlockDepositedAssets and are excluded.
        assertEq(
            vault.borrowableTotalAssets(),
            taBefore,
            "all same-block deposits excluded; borrowable back to pre-deposit"
        );
    }

    function test_borrowableTotalAssets_zeroFloor_neverUnderflows() public view {
        // Empty vault, no deposits this block: must return 0 (not revert/underflow).
        assertEq(vault.totalAssets(), 0, "fresh vault has zero assets");
        assertEq(vault.borrowableTotalAssets(), 0, "borrowableTotalAssets zero-floors on empty vault");
    }

    function test_borrowableTotalAssets_depositRewardsNotCountedAsSameBlockDeposit() public {
        // Seed liquidity in a PRIOR block so it is fully borrowable.
        _selfDeposit(alice, 1000e6);
        vm.roll(BLOCK_START + 1);
        uint256 borrowableBefore = vault.borrowableTotalAssets();
        assertEq(borrowableBefore, 1000e6, "seeded liquidity fully borrowable next block");

        // depositRewards flows through safeTransferFrom directly, NOT _deposit,
        // so it must NOT register as a same-block deposit. (The reward inflow
        // vests over the epoch; totalAssets is unchanged at the moment of deposit,
        // and borrowableTotalAssets must NOT be reduced by the reward path.)
        uint256 rewardAmount = 200e6;
        usdc.mint(address(this), rewardAmount);
        usdc.approve(address(vault), rewardAmount);
        // This test contract is treated as a portfolio by MockPortfolioFactory.
        vault.depositRewards(rewardAmount);

        // borrowableTotalAssets must equal totalAssets (no same-block-deposit
        // exclusion triggered by the reward inflow).
        assertEq(
            vault.borrowableTotalAssets(),
            vault.totalAssets(),
            "depositRewards must not register as a same-block deposit"
        );
        // And the pre-existing borrowable liquidity is not reduced by the reward path.
        assertEq(
            vault.borrowableTotalAssets(),
            borrowableBefore,
            "reward inflow does not shrink borrowable supply (vests over epoch)"
        );
    }
}
