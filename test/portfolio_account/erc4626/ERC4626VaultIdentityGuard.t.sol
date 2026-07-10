// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * ERC4626VaultIdentityGuard
 *
 * Feature under test (NOT YET IMPLEMENTED -- these tests are written TEST-FIRST)
 * ---------------------------------------------------------------------------
 * Hardening so a diamond re-cut to a different collateral vault cannot silently
 * reinterpret existing account storage. The intended fix ("enforce at managers"):
 *
 *   - ERC4626PortfolioFactoryConfig holds a set-once `collateralVault`
 *     (setCollateralVault / getCollateralVault). It already exists and compiles.
 *   - ERC4626CollateralManager gains a guard in its two snapshot chokepoints
 *     (_snapshotIfNeeded and _snapshotIfNeededRepay) that reverts
 *     VaultMismatch(stored, provided) whenever
 *         config.getCollateralVault() != address(0)
 *      && config.getCollateralVault() != vault   (the facet-supplied vault)
 *
 * Because the guard lives in the snapshot chokepoints, it covers every strict
 * mutating entry: addCollateral, removeCollateral, increaseTotalDebt (borrow),
 * decreaseTotalDebt (pay), removeSharesForYield, and snapshotShortfall. Views
 * stay unguarded.
 *
 * CURRENT STATE: the error `VaultMismatch` is declared and the config exists,
 * but the GUARD LOGIC IS NOT WIRED IN. So the mismatch tests below (group #1)
 * MUST FAIL right now -- the operations succeed instead of reverting. They will
 * pass once the guard is added.
 *
 * Test groups:
 *   1. Mismatch reverts on each strict entry point  -> MUST FAIL on current code
 *   2. Matching vault passes                        -> should pass now
 *   3. Unset config is not bricked                  -> should pass now
 *   4. Config set-once semantics                    -> should pass now
 *
 * Harness mirrors the other ERC4626 facet tests for diamond/config/vault wiring,
 * but swaps the base PortfolioFactoryConfig for ERC4626PortfolioFactoryConfig so
 * getCollateralVault() is available, and binds facets to a SECOND vault (B) to
 * drive the mismatch.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";

import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";

import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";

import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {ERC4626PortfolioFactoryConfig} from "../../../src/facets/account/erc4626/ERC4626PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";

import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";

import {AccessControl} from "../../../src/facets/account/utils/AccessControl.sol";

import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ERC4626GuardHarnessFacet
 * @dev Test-only facet that exposes the two manager chokepoint entry points that
 *      are NOT directly facet-routed in production (snapshotShortfall and
 *      removeSharesForYield). It forwards the facet-bound vault and the diamond's
 *      configured PortfolioFactoryConfig, exactly as the real facets do, so the
 *      guard sees the same (config, vault) pair. Bound to a single vault via its
 *      immutable, mirroring the real facets' vault binding.
 */
contract ERC4626GuardHarnessFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    address public immutable _vault;

    constructor(address portfolioFactory, address vault) {
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _vault = vault;
    }

    /// @dev Routes to ERC4626CollateralManager.snapshotShortfall -> _snapshotIfNeeded (guarded).
    function harnessSnapshotShortfall() external {
        ERC4626CollateralManager.snapshotShortfall(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _vault
        );
    }

    /// @dev Routes to ERC4626CollateralManager.removeSharesForYield -> _snapshotIfNeeded (guarded).
    ///      The guard fires before the in-manager isAuthorizedCaller check, so an
    ///      unauthorized direct call still trips the guard when vault mismatches.
    function harnessRemoveSharesForYield(uint256 shares) external {
        ERC4626CollateralManager.removeSharesForYield(
            address(_portfolioFactory.portfolioFactoryConfig()),
            _vault,
            shares
        );
    }
}

contract ERC4626VaultIdentityGuardTest is Test {
    // Diamond infrastructure
    PortfolioFactory internal _portfolioFactory;
    PortfolioManager internal _portfolioManager;
    FacetRegistry internal _facetRegistry;

    // Config (ERC4626 subclass that carries the set-once collateralVault)
    ERC4626PortfolioFactoryConfig internal _config;
    LoanConfig internal _loanConfig;

    // Two vaults: A = canonical (set in config), B = what the facets are bound to.
    MockERC20 internal _underlying;
    MockERC4626 internal _vaultA;
    MockERC4626 internal _vaultB;

    // Lending vault (the loan contract / lending pool)
    address internal _lendingVault;

    address internal _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal _user = address(0x40ac2e);
    address internal _authorizedCaller = address(0xaaaaa);
    address internal _payer = address(0xBADADD);

    address internal _portfolioAccount;

    uint256 internal constant DEPOSIT = 1000e6;
    uint256 internal constant BORROW = 100e6;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------
    function setUp() public {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory factory, FacetRegistry registry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-vault-identity-guard")))
        );
        _portfolioFactory = factory;
        _facetRegistry = registry;

        // Tokens / vaults
        _underlying = new MockERC20("Mock USDC", "mUSDC", 6);
        _vaultA = new MockERC4626(address(_underlying), "Vault A", "vA", 6);
        _vaultB = new MockERC4626(address(_underlying), "Vault B", "vB", 6);

        // Lending vault (LendingVault implements getDebtBalance, required by _syncDebt)
        _setupLendingVault();

        // LoanConfig behind a UUPS proxy (impl constructor disables initializers).
        LoanConfig loanConfigImpl = new LoanConfig();
        ERC1967Proxy loanConfigProxy = new ERC1967Proxy(
            address(loanConfigImpl),
            abi.encodeWithSelector(LoanConfig.initialize.selector, _owner, uint256(2000), uint256(500), uint256(100))
        );
        _loanConfig = LoanConfig(address(loanConfigProxy));
        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000);
        _loanConfig.setLtv(7000);

        // ERC4626PortfolioFactoryConfig behind a UUPS proxy, initialized for this factory.
        _config = _deployErc4626Config(address(_portfolioFactory), _owner);
        _config.setLoanContract(_lendingVault);
        _config.setLoanConfig(address(_loanConfig));
        // NOTE: collateralVault is intentionally NOT set here. Each test sets it
        // (or leaves it unset) to exercise the matching / mismatch / unset cases.

        _portfolioFactory.setPortfolioFactoryConfig(address(_config));
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Seed balances
        _underlying.mint(_user, DEPOSIT * 10);
        _underlying.mint(_lendingVault, 1_000_000e6);
    }

    function _setupLendingVault() internal {
        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        LendingVault vault = LendingVault(address(proxy));
        vault.initialize(
            address(_underlying),
            address(_portfolioFactory),
            _owner,
            "Lending Vault",
            "lVAULT",
            0
        );
        _lendingVault = address(vault);
    }

    function _deployErc4626Config(address factory, address owner_) internal returns (ERC4626PortfolioFactoryConfig) {
        ERC4626PortfolioFactoryConfig impl = new ERC4626PortfolioFactoryConfig();
        bytes memory initData = abi.encodeWithSelector(
            PortfolioFactoryConfig.initialize.selector,
            owner_,
            factory
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return ERC4626PortfolioFactoryConfig(address(proxy));
    }

    // -------------------------------------------------------------------------
    // Facet registration helpers
    // -------------------------------------------------------------------------

    /// @dev Register the collateral + lending facets bound to `vault`, plus the
    ///      guard harness facet. All ERC4626 selectors collapse to a single
    ///      collateral manager storage slot regardless of which vault the facet
    ///      is bound to.
    function _registerFacets(address vault) internal returns (ERC4626CollateralFacet collat, ERC4626LendingFacet lending, ERC4626GuardHarnessFacet harness) {
        vm.startPrank(_owner);

        DeployERC4626CollateralFacet collatDeployer = new DeployERC4626CollateralFacet();
        collat = collatDeployer.deploy(address(_portfolioFactory), vault);

        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        lending = lendingDeployer.deploy(address(_portfolioFactory), address(_underlying), vault);

        harness = new ERC4626GuardHarnessFacet(address(_portfolioFactory), vault);
        bytes4[] memory hsel = new bytes4[](2);
        hsel[0] = ERC4626GuardHarnessFacet.harnessSnapshotShortfall.selector;
        hsel[1] = ERC4626GuardHarnessFacet.harnessRemoveSharesForYield.selector;
        _facetRegistry.registerFacet(address(harness), hsel, "ERC4626GuardHarnessFacet");

        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Collateral / borrow / pay drivers
    // -------------------------------------------------------------------------

    function _stageSharesToPortfolio(MockERC4626 vault, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(_user);
        _underlying.approve(address(vault), assets);
        shares = vault.deposit(assets, _user);
        vault.transfer(_portfolioAccount, shares);
        vm.stopPrank();
    }

    function _multicall(bytes memory data) internal {
        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = data;
        _portfolioManager.multicall(calls, facs);
        vm.stopPrank();
    }

    function _expectVaultMismatch(address stored, address provided) internal {
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626CollateralManager.VaultMismatch.selector, stored, provided)
        );
    }

    // =========================================================================
    // GROUP 1: MISMATCH MUST REVERT (these MUST FAIL on current un-guarded code)
    //
    // config.collateralVault == vaultA, but facets are bound to vaultB. Every
    // strict mutating entry point must revert VaultMismatch(vaultA, vaultB).
    // =========================================================================

    function test_mismatch_addCollateral_reverts() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        _registerFacets(address(_vaultB));

        // Stake vaultB shares into the portfolio so the only thing that can stop
        // the op is the guard, not a balance check (guard fires before it anyway).
        uint256 shares = _stageSharesToPortfolio(_vaultB, DEPOSIT);

        _expectVaultMismatch(address(_vaultA), address(_vaultB));
        _multicall(abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares));
    }

    function test_mismatch_removeCollateral_reverts() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        _registerFacets(address(_vaultB));

        // No collateral exists on the (B-bound) slot; the guard must fire before
        // the "Insufficient collateral shares" require.
        _expectVaultMismatch(address(_vaultA), address(_vaultB));
        _multicall(abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, uint256(1)));
    }

    function test_mismatch_borrow_reverts() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        (, ERC4626LendingFacet lending, ) = _registerFacets(address(_vaultB));
        lending; // silence

        _expectVaultMismatch(address(_vaultA), address(_vaultB));
        _multicall(abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, BORROW));
    }

    /// @dev Repay is intentionally lenient: pay() routes through the unguarded
    ///      _snapshotIfNeededRepay, so a vault mismatch does NOT block debt
    ///      paydown. The guard lives on the borrow side only; this pins the
    ///      deliberate borrow-strict / repay-lenient asymmetry.
    function test_mismatch_pay_doesNotRevert() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        _registerFacets(address(_vaultB));

        _underlying.mint(_payer, BORROW);
        vm.prank(_payer);
        _underlying.approve(_portfolioAccount, BORROW);

        // No expectRevert: pay() must succeed despite config(vaultA) != facet(vaultB).
        vm.prank(_payer);
        ERC4626LendingFacet(_portfolioAccount).pay(BORROW);
    }

    function test_mismatch_removeSharesForYield_reverts() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        ( , , ERC4626GuardHarnessFacet harness) = _registerFacets(address(_vaultB));
        harness; // routed through the diamond below

        // removeSharesForYield snapshots (guarded) before its isAuthorizedCaller
        // check, so even this direct call trips the guard first.
        _expectVaultMismatch(address(_vaultA), address(_vaultB));
        ERC4626GuardHarnessFacet(_portfolioAccount).harnessRemoveSharesForYield(1);
    }

    function test_mismatch_snapshotShortfall_reverts() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        _registerFacets(address(_vaultB));

        _expectVaultMismatch(address(_vaultA), address(_vaultB));
        ERC4626GuardHarnessFacet(_portfolioAccount).harnessSnapshotShortfall();
    }

    // =========================================================================
    // GROUP 2: MATCHING VAULT PASSES
    //
    // config.collateralVault == vaultA and facets are bound to vaultA. The same
    // operations succeed (no VaultMismatch).
    // =========================================================================

    function test_match_fullFlow_succeeds() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        ( , , ERC4626GuardHarnessFacet harness) = _registerFacets(address(_vaultA));
        harness;

        // addCollateral
        uint256 shares = _stageSharesToPortfolio(_vaultA, DEPOSIT);
        _multicall(abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares));
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), shares, "shares tracked");

        // snapshotShortfall (no revert)
        ERC4626GuardHarnessFacet(_portfolioAccount).harnessSnapshotShortfall();

        // borrow
        _multicall(abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, BORROW));
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), BORROW, "debt recorded");

        // pay (full)
        _underlying.mint(_payer, BORROW);
        vm.prank(_payer);
        _underlying.approve(_portfolioAccount, BORROW);
        vm.prank(_payer);
        ERC4626LendingFacet(_portfolioAccount).pay(BORROW);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "debt cleared");

        // removeCollateral (full exit, no debt remaining)
        _multicall(abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, shares));
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), 0, "collateral exited");
    }

    function test_match_removeSharesForYield_succeeds() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));

        ( , , ERC4626GuardHarnessFacet harness) = _registerFacets(address(_vaultA));
        harness;

        // Add collateral, then create yield so removeSharesForYield can remove
        // surplus shares without touching principal.
        uint256 shares = _stageSharesToPortfolio(_vaultA, DEPOSIT);
        _multicall(abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares));

        // Simulate yield: send underlying into the vault, inflating share value.
        _underlying.mint(_owner, DEPOSIT);
        vm.startPrank(_owner);
        _underlying.approve(address(_vaultA), DEPOSIT);
        _vaultA.simulateYield(DEPOSIT);
        vm.stopPrank();

        // Remove a small number of surplus shares (well within the new yield),
        // through the authorized caller (manager requires isAuthorizedCaller).
        vm.prank(_authorizedCaller);
        ERC4626GuardHarnessFacet(_portfolioAccount).harnessRemoveSharesForYield(shares / 4);

        assertEq(
            ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(),
            shares - shares / 4,
            "surplus shares removed without VaultMismatch"
        );
    }

    // =========================================================================
    // GROUP 3: UNSET CONFIG IS NOT BRICKED
    //
    // config.collateralVault == address(0). Operations against a facet bound to
    // ANY vault must NOT revert VaultMismatch -- pre-rollout markets keep working.
    // =========================================================================

    function test_unsetConfig_operationsSucceed() public {
        // Deliberately do NOT call setCollateralVault.
        assertEq(_config.getCollateralVault(), address(0), "precondition: collateralVault unset");

        ( , , ERC4626GuardHarnessFacet harness) = _registerFacets(address(_vaultB));
        harness;

        uint256 shares = _stageSharesToPortfolio(_vaultB, DEPOSIT);

        // addCollateral
        _multicall(abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares));
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), shares, "shares tracked w/ unset config");

        // borrow
        _multicall(abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, BORROW));
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), BORROW, "debt recorded w/ unset config");

        // snapshotShortfall (no revert)
        ERC4626GuardHarnessFacet(_portfolioAccount).harnessSnapshotShortfall();

        // pay
        _underlying.mint(_payer, BORROW);
        vm.prank(_payer);
        _underlying.approve(_portfolioAccount, BORROW);
        vm.prank(_payer);
        ERC4626LendingFacet(_portfolioAccount).pay(BORROW);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "debt cleared w/ unset config");
    }

    // =========================================================================
    // GROUP 4: CONFIG SET-ONCE SEMANTICS
    // =========================================================================

    function test_config_setCollateralVault_setsAndReads() public {
        vm.prank(_owner);
        _config.setCollateralVault(address(_vaultA));
        assertEq(_config.getCollateralVault(), address(_vaultA), "getter returns set value");
    }

    function test_config_setCollateralVault_zeroReverts() public {
        vm.prank(_owner);
        vm.expectRevert(ERC4626PortfolioFactoryConfig.ZeroCollateralVault.selector);
        _config.setCollateralVault(address(0));
    }

    function test_config_setCollateralVault_secondSetReverts() public {
        vm.startPrank(_owner);
        _config.setCollateralVault(address(_vaultA));
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626PortfolioFactoryConfig.CollateralVaultAlreadySet.selector, address(_vaultA))
        );
        _config.setCollateralVault(address(_vaultB));
        vm.stopPrank();
    }

    function test_config_setCollateralVault_onlyOwner() public {
        vm.prank(_user);
        vm.expectRevert();
        _config.setCollateralVault(address(_vaultA));
    }
}
