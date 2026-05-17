// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { _mint(msg.sender, 1_000_000e6); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactory is IPortfolioFactory {
    function isPortfolio(address p) external pure override returns (bool) { return p != address(0); }
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

/**
 * @notice Regression suite for the floored-rate dust leak in DynamicFeesVault
 *         reward streaming.
 *
 *         depositRewards sets `newRate = (remaining + amount) / duration`
 *         (floored) but books the full deposit into `totalUnsettledRewards`.
 *         Over a full epoch only `newRate * duration` ever vests, so the
 *         floor remainder sits in `totalUnsettledRewards` forever — and is
 *         subtracted from `totalAssets()`, persistently understating NAV.
 *
 *         Fix: when an epoch boundary is crossed inside _processGlobalVesting,
 *         consume the residual `totalUnsettledRewards` into the same
 *         lender-premium / borrower-credit split as the rest of the epoch's
 *         vesting.
 */
contract DynamicFeesVaultDustSweepTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;
    address public owner = address(0xA);
    address public user1 = address(0xB);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc),
            "USDC Vault",
            "vUSDC",
            address(portfolioFactory),
            address(this),
            uint256(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, address(this));
    }

    function _fundAndDepositRewards(address user, uint256 amount) internal {
        vm.startPrank(user);
        deal(address(usdc), user, amount);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    /// @notice Single user, single deposit at epoch start. Amount is chosen so
    ///         that `amount % WEEK != 0`, guaranteeing floor-division dust.
    ///         After the boundary settle, `totalUnsettledRewards` MUST be 0.
    function test_epochBoundary_sweepsResidualDust_singleUser() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        // 100e6 + 1 wei: WEEK = 604800. Floor(100000001/604800) = 165.
        // 165*604800 = 99792000. Dust = 208001 wei.
        uint256 amount = 100e6 + 1;
        _fundAndDepositRewards(user1, amount);

        assertEq(vault.getTotalUnsettledRewards(), amount, "stream funded");

        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        assertEq(
            vault.getTotalUnsettledRewards(),
            0,
            "boundary settle must consume all unsettled rewards"
        );
    }

    /// @notice Multi-epoch accumulation: without the fix, dust compounds across
    ///         consecutive deposits. Re-streaming inside the same epoch can
    ///         also leave dust, but the boundary sweep should drain it.
    function test_epochBoundary_sweepsResidualDust_multipleEpochs() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        // Epoch 2: non-divisible amount.
        _fundAndDepositRewards(user1, 100e6 + 1);

        // Mid-epoch re-stream with another non-divisible top-up — creates
        // a fresh floor remainder on top of the first one.
        vm.warp(EPOCH_2 + WEEK / 3);
        _fundAndDepositRewards(user1, 37e6 + 1);

        vm.warp(EPOCH_3);
        vault.settleRewards(user1);
        assertEq(
            vault.getTotalUnsettledRewards(),
            0,
            "epoch 3 boundary: all dust consumed"
        );

        // New epoch, fresh non-divisible deposit.
        _fundAndDepositRewards(user1, 50e6 + 7);
        vm.warp(EPOCH_4);
        vault.settleRewards(user1);
        assertEq(
            vault.getTotalUnsettledRewards(),
            0,
            "epoch 4 boundary: all dust consumed"
        );
    }

    /// @notice totalAssets() must not lose value across epoch boundaries once
    ///         streams complete. Pre-fix, dust subtracted permanently from NAV.
    function test_totalAssets_preservedAfterStreamCompletes() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 amount = 100e6 + 1;
        _fundAndDepositRewards(user1, amount);

        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        // After the stream fully drains and any unvested-premium epoch passes,
        // the only remaining adjustment to totalAssets should be the realised
        // lender premium (already vested). Specifically, totalUnsettledRewards
        // must not pin any dust onto the deduction side.
        assertEq(
            vault.getTotalUnsettledRewards(),
            0,
            "no dust pinned in totalUnsettledRewards"
        );

        // Sanity: gross-of-deductions check — vault balance + outstanding debt
        // should equal totalAssets() plus unvested premium and escrow only.
        // We don't have direct getters for every internal field here; the dust
        // invariant above is the load-bearing assertion. This sub-assertion is
        // a soft-bound that totalAssets is at least the initial deposit minus
        // the lender premium portion (~20% at 50% util given the default fee
        // calculator, but this depends on settle timing; assert lower bound).
        assertGt(vault.totalAssets(), 999e6, "totalAssets close to deposit");
    }
}
