// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * LiveVeHydrexSimpleDeploy.t.sol -- end-to-end fork test for the script
 *   script/portfolio_account/veHydrex/DeployVeHydrexSimple.s.sol
 * ===========================================================================
 *
 * What this test exercises:
 *
 *   Phase A (multisig)  - PortfolioManager.deployFactory(salt) is called from
 *                         the prod multisig. Produces a fresh PortfolioFactory
 *                         + FacetRegistry, both owned by the multisig.
 *
 *   Phase B (deployer)  - inherited _deploy() runs as the deployer EOA.
 *                         _registerFacet calls silently no-op (the broadcaster
 *                         is not the FacetRegistry owner; the script emits
 *                         Safe calldata in that branch). transferOwnership
 *                         hands the 4 owned contracts to the multisig.
 *
 *   Phase C (multisig)  - the multisig registers all 7 facets, calls
 *                         setPortfolioFactoryConfig on the factory, and
 *                         acceptOwnership on the 4 contracts.
 *
 *   Smoke test          - seed vault liquidity, transfer a live veHYDX into a
 *                         portfolio account, borrow USDC (with origination fee
 *                         routed to the treasury), repay, and pull collateral
 *                         back out.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork make test \
 *     ARGS='--match-contract LiveVeHydrexSimpleDeploy -vvv'
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {VeHydrexSimpleDeploy} from "../../../../script/portfolio_account/veHydrex/DeployVeHydrexSimple.s.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";

/// @dev Minimal ERC721 receiver. Hydrex's veHYDREX contract calls
///      onERC721Received even on EOA recipients (the live bytecode does not
///      use Address.isContract before the callback), so removeCollateral
///      to an EOA reverts. Tests use this contract as the portfolio owner so
///      collateral can be pulled out cleanly.
contract _Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @dev Concrete subclass of the production deploy script that lets the fork
///      test inject a freshly-deployed (PortfolioFactory, FacetRegistry) pair
///      instead of the hard-coded prod addresses. Everything else in
///      VeHydrexSimpleDeploy is unchanged.
contract LiveVeHydrexSimpleDeploy is VeHydrexSimpleDeploy, Test {
    address internal _testFactory;
    address internal _testFacetRegistry;

    function portfolioFactoryAddress() public view override returns (address) {
        return _testFactory;
    }

    function facetRegistryAddress() public view override returns (address) {
        return _testFacetRegistry;
    }

    // ============ Live Base addresses (from VeHydrex.fork.t.sol) ============
    // The pinned block is the same as VeHydrex.fork.t.sol::BLOCK_PIN; at this
    // block HOLDER owns the three veHYDX tokenIds used here. The script's
    // BASE_SWAP_CONFIG must also have bytecode at this block -- we sanity
    // check that and skip the test if it doesn't.
    uint256 internal constant BLOCK_PIN = 46_185_527;
    address internal constant HOLDER = 0x97BE22DBb49C88451fBd1099F59EED963d9d8A12;
    // HOLDER_TOKEN: at BLOCK_PIN, HOLDER owns id 91518 (the "B" token from
    // VeHydrex.fork.t.sol's pinned set). The "A" token (91486) is owned by
    // a different address at this block and "C" (100108) does not yet exist.
    uint256 internal constant HOLDER_TOKEN_A = 91518;
    address internal constant VE_HYDREX = 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1;

    // Borrow/pay smoke-test parameters.
    //
    // HOLDER_TOKEN_A at the pinned block has lockDetails.amount ~= 89.78 HYDX.
    // With rewardsRate = 285_0 (28.5%) and multiplier = 52, the per-token max
    // loan computes as:
    //     amount * 2850 / 1e6 * 52 / 1e12  ~=  89.78 * 2850 * 52 / 1e6
    //                                      ~=  13.3 USDC
    //
    // Picking a 5 USDC borrow comfortably clears the per-collateral cap and
    // is unaffected by the 80% utilization cap (10k USDC of liquidity).
    // ORIGINATION_FEE_BPS = 80 (0.8%) means borrower nets 4.96 USDC and the
    // treasury receives 0.04 USDC.
    uint256 internal constant BORROW_AMOUNT = 5e6;
    uint256 internal constant ORIGINATION_FEE = (BORROW_AMOUNT * ORIGINATION_FEE_BPS) / 10_000; // 0.04 USDC
    uint256 internal constant BORROW_NET = BORROW_AMOUNT - ORIGINATION_FEE;                    // 4.96 USDC

    // Vault liquidity seeded by the test. Must be > BORROW_AMOUNT and far
    // below the maxUtilizationBps cap so the borrow doesn't trip the
    // utilization gate (handled by maxUtilizationBps set in Phase C).
    uint256 internal constant DEPOSIT_AMOUNT = 10_000e6;

    bool internal forkActive;

    function setUp() public {
        // Prefer BASE_RPC_URL (alchemy / private endpoint) over the default
        // foundry.toml "base" alias (public mainnet.base.org), which has
        // returned 502s during testing. Soft-skip if neither is reachable.
        string memory rpcUrl;
        try vm.envString("BASE_RPC_URL") returns (string memory u) {
            rpcUrl = u;
        } catch {
            rpcUrl = "base";
        }
        try vm.createSelectFork(rpcUrl, BLOCK_PIN) {
            forkActive = true;
        } catch {
            forkActive = false;
            return;
        }

        // SwapConfig must exist at the pin or the script reverts during
        // RewardsConfigFacet / RewardsProcessingFacet deployment (the facets
        // store the address as an immutable; the live SwapConfig contract is
        // only required for proper rewards processing, not for the
        // construct-and-register flow, but we still check that the address
        // resolves to bytecode for hygiene).
        if (BASE_SWAP_CONFIG.code.length == 0) {
            console.log("BASE_SWAP_CONFIG has no bytecode at fork pin -- skipping");
            vm.skip(true);
            return;
        }

        // ============ Phase A: multisig deploys factory+registry ============
        // Use a salt distinct from the prod "hydrex-usdc" salt so we don't
        // collide with the already-deployed prod factory at
        // 0x74488Ee5f1599CC4b89Fa42134b9c5a142Cba7D6.
        PortfolioManager pm = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        vm.startPrank(MULTISIG_ADDRESS);
        (PortfolioFactory pf, FacetRegistry fr) = pm.deployFactory(keccak256("hydrex-usdc-test"));
        vm.stopPrank();
        _testFactory = address(pf);
        _testFacetRegistry = address(fr);

        // ============ Phase B: deployer runs the script body ============
        // Note: _deploy() uses `new` for everything (no broadcast). The
        // _registerFacet calls inside _deploy detect that the broadcaster is
        // not the registry owner and silently no-op (emitting Safe calldata
        // via console.log). transferOwnership is called as the deployer; the
        // multisig must acceptOwnership in Phase C.
        vm.startPrank(DEPLOYER_ADDRESS);
        _deploy();
        vm.stopPrank();

        // ============ Phase C: multisig wires the diamond ============
        vm.startPrank(MULTISIG_ADDRESS);

        // 1) Register all 7 facets using the script-defined selector helpers.
        FacetRegistry registry = FacetRegistry(_testFacetRegistry);
        registry.registerFacet(claimingFacet, _claimingSelectors(), "VeHydrexClaimingFacet");
        registry.registerFacet(collateralFacet, _collateralSelectors(), "HydrexCollateralFacet");
        registry.registerFacet(lendingFacet, _lendingSelectors(), "HydrexLendingFacet");
        registry.registerFacet(votingFacet, _votingSelectors(), "VeHydrexFacet");
        registry.registerFacet(votingEscrowFacet, _votingEscrowSelectors(), "VeHydrexVotingEscrowFacet");
        registry.registerFacet(rewardsProcessingFacet, _rewardsProcessingSelectors(), "HydrexRewardsProcessingFacet");
        registry.registerFacet(rewardsConfigFacet, _rewardsConfigSelectors(), "RewardsConfigFacet");

        // 2) Bind the factory to its config.
        PortfolioFactory(_testFactory).setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        // 3) Accept ownership on all 4 Ownable2Step contracts.
        _portfolioFactoryConfig.acceptOwnership();
        _votingConfig.acceptOwnership();
        _loanConfig.acceptOwnership();
        _lendingVault.acceptOwnership();

        // 4) Set the LoanConfig knobs the script intentionally leaves blank
        //    (rewardsRate, multiplier are governance-tuned post-deploy). The
        //    smoke-test borrow needs non-zero getMaxLoan, so we drive these
        //    here. Picked to match the standard live-config values used in
        //    other simple-path deployments.
        _loanConfig.setRewardsRate(285_0);   // 28.5% rewards rate
        _loanConfig.setMultiplier(52);       // 52x rewards-rate multiplier
        _loanConfig.setMaxUtilizationBps(8000); // 80% utilization cap

        vm.stopPrank();

        vm.label(_testFactory, "PortfolioFactory");
        vm.label(_testFacetRegistry, "FacetRegistry");
        vm.label(address(_lendingVault), "LendingVault");
        vm.label(address(_loanConfig), "LoanConfig");
        vm.label(address(_votingConfig), "VotingConfig");
        vm.label(address(_portfolioFactoryConfig), "PortfolioFactoryConfig");
        vm.label(USDC, "USDC");
        vm.label(VE_HYDREX, "veHYDREX");
    }

    // ============================================================
    // 1. Final-state assertions: every wire from the deploy script
    //    resolves the way the prod choreography expects.
    // ============================================================
    function test_LiveDeployment_FinalState() public {
        if (!forkActive) {
            vm.skip(true);
            return;
        }

        // PortfolioFactory <-> config wiring.
        assertEq(
            address(PortfolioFactory(_testFactory).portfolioFactoryConfig()),
            address(_portfolioFactoryConfig),
            "factory.portfolioFactoryConfig"
        );
        assertEq(_portfolioFactoryConfig.getLoanContract(), address(_lendingVault), "config.loanContract");
        assertEq(_portfolioFactoryConfig.getVoteConfig(), address(_votingConfig), "config.voteConfig");
        assertEq(address(_portfolioFactoryConfig.getLoanConfig()), address(_loanConfig), "config.loanConfig");

        // Lending vault state.
        assertEq(_lendingVault.owner(), MULTISIG_ADDRESS, "vault.owner == multisig");
        assertEq(_lendingVault.originationFeeBps(), ORIGINATION_FEE_BPS, "vault.originationFeeBps");
        assertEq(_lendingVault.asset(), USDC, "vault.asset == USDC");
        assertEq(
            keccak256(bytes(_lendingVault.name())),
            keccak256(bytes("40ACRES-HYDREX-USDC-VAULT")),
            "vault.name"
        );
        assertEq(
            keccak256(bytes(_lendingVault.symbol())),
            keccak256(bytes("40ACRES-HYDREX-USDC")),
            "vault.symbol"
        );

        // Owned-contract ownership transferred + accepted.
        assertEq(_votingConfig.owner(), MULTISIG_ADDRESS, "votingConfig.owner");
        assertEq(_loanConfig.owner(), MULTISIG_ADDRESS, "loanConfig.owner");
        assertEq(_portfolioFactoryConfig.owner(), MULTISIG_ADDRESS, "portfolioFactoryConfig.owner");

        // LoanConfig curve params survived ownership transfer.
        (uint256 base, uint256 slope, uint256 kink, uint256 cap,) = _loanConfig.getLenderPremiumCurve();
        assertEq(base, CURVE_BASE, "curve.base");
        assertEq(slope, CURVE_SLOPE, "curve.slope");
        assertEq(kink, CURVE_KINK, "curve.kink");
        assertEq(cap, CURVE_CAP, "curve.cap");

        // Facet registration: each facet must resolve through the registry
        // for the first selector in its bundle. Using the first selector is
        // a sufficient smoke test that the bundle was registered intact.
        FacetRegistry registry = FacetRegistry(_testFacetRegistry);
        assertEq(registry.getFacetForSelector(_claimingSelectors()[0]), claimingFacet, "registry.claiming");
        assertEq(registry.getFacetForSelector(_collateralSelectors()[0]), collateralFacet, "registry.collateral");
        assertEq(registry.getFacetForSelector(_lendingSelectors()[0]), lendingFacet, "registry.lending");
        assertEq(registry.getFacetForSelector(_votingSelectors()[0]), votingFacet, "registry.voting");
        assertEq(
            registry.getFacetForSelector(_votingEscrowSelectors()[0]),
            votingEscrowFacet,
            "registry.votingEscrow"
        );
        assertEq(
            registry.getFacetForSelector(_rewardsProcessingSelectors()[0]),
            rewardsProcessingFacet,
            "registry.rewardsProcessing"
        );
        assertEq(
            registry.getFacetForSelector(_rewardsConfigSelectors()[0]),
            rewardsConfigFacet,
            "registry.rewardsConfig"
        );

        // VotingConfig seeded the script's initial approved-pools snapshot.
        address[] memory pools = _initialApprovedPools();
        assertTrue(_votingConfig.isApprovedPool(pools[0]), "initialApprovedPools[0] approved");
    }

    // ============================================================
    // 2. Borrow / repay smoke test: validates that a portfolio account
    //    routed through the freshly-wired diamond can actually move USDC
    //    from the vault and back.
    //
    //    Strategy: transfer HOLDER's live veHYDX into a portfolio account
    //    we create through the new factory. Seed vault liquidity. Borrow
    //    100 USDC; assert origination fee lands in the vault treasury
    //    (= vault.owner() == multisig, since setTreasury was never called).
    //    Repay 100 USDC; assert debt clears. Pull collateral out.
    // ============================================================
    function test_LiveDeployment_BorrowRepayWiring() public {
        if (!forkActive) {
            vm.skip(true);
            return;
        }

        // Use a contract receiver as the portfolio owner so the eventual
        // removeCollateral can return the veNFT via safeTransferFrom without
        // tripping Hydrex's ERC721Receiver check (the live VE bytecode calls
        // onERC721Received unconditionally, even on EOA recipients).
        address alice = address(new _Receiver());
        vm.label(alice, "alice");

        // Pre-flight: verify HOLDER still owns the token at the pin. If a
        // future re-pin drifts, the test surfaces a clean error instead of
        // an opaque revert deep in safeTransferFrom.
        require(
            IERC721(VE_HYDREX).ownerOf(HOLDER_TOKEN_A) == HOLDER,
            "fork drift: HOLDER does not own HOLDER_TOKEN_A at pin"
        );

        // Create the portfolio account through the multisig-wired factory.
        address account = PortfolioFactory(_testFactory).createAccount(alice);
        vm.label(account, "portfolioAccount");

        // Seed vault liquidity from this contract (test as LP). The vault's
        // _deposit hook stores lastDepositBlock, which only matters for
        // withdraw -- borrows are unaffected.
        deal(USDC, address(this), DEPOSIT_AMOUNT);
        IERC20(USDC).approve(address(_lendingVault), DEPOSIT_AMOUNT);
        _lendingVault.deposit(DEPOSIT_AMOUNT, address(this));
        assertEq(
            IERC20(USDC).balanceOf(address(_lendingVault)),
            DEPOSIT_AMOUNT,
            "vault holds deposited USDC"
        );

        // Move the veHYDX into the portfolio account. The receiver hook on
        // VeHydrexVotingEscrowFacet tracks it as collateral via the
        // HydrexCollateralManager addLockedCollateralUnchecked / locked
        // tracker (the unconverted path).
        vm.prank(HOLDER);
        IERC721(VE_HYDREX).safeTransferFrom(HOLDER, account, HOLDER_TOKEN_A);
        assertEq(IERC721(VE_HYDREX).ownerOf(HOLDER_TOKEN_A) , account, "veHYDX moved to account");

        // Sanity: collateral is tracked locally (totalLockedCollateral > 0).
        // Reading through ICollateralFacet routes through the registered
        // HydrexCollateralFacet.
        assertGt(
            BaseCollateralFacet(account).getTotalLockedCollateral(),
            0,
            "tracked collateral > 0 after veNFT transfer-in"
        );

        // Snapshot balances. Treasury = vault.owner() = multisig (setTreasury
        // never called by the script -- the LendingVault.getTreasury() fallback
        // returns owner() when the treasury slot is zero).
        address treasury = _lendingVault.getTreasury();
        assertEq(treasury, MULTISIG_ADDRESS, "treasury fallback == multisig owner");
        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        // Borrow -- must route through the PortfolioManager.multicall path
        // because BaseLendingFacet.borrow has onlyPortfolioManagerMulticall.
        PortfolioManager pm = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, BORROW_AMOUNT);
        address[] memory facs = new address[](1);
        facs[0] = _testFactory;

        vm.prank(alice);
        pm.multicall(cd, facs);

        assertEq(
            IERC20(USDC).balanceOf(alice) - aliceBefore,
            BORROW_NET,
            "alice received borrow net of origination fee"
        );
        assertEq(
            IERC20(USDC).balanceOf(treasury) - treasuryBefore,
            ORIGINATION_FEE,
            "treasury received origination fee"
        );
        assertEq(
            _lendingVault.activeAssets(),
            BORROW_AMOUNT,
            "vault.activeAssets == outstanding debt"
        );
        assertEq(
            BaseCollateralFacet(account).getTotalDebt(),
            BORROW_AMOUNT,
            "collateral manager tracks full debt"
        );

        // Repay. pay() is permissionless (only nonReentrant) -- alice calls
        // it directly. She must approve the account to pull USDC.
        //
        // Alice only received `BORROW_NET` after the origination fee was
        // skimmed by the vault. To fully repay the loan principal she needs
        // ORIGINATION_FEE more USDC; top her up so the test asserts a clean
        // debt-zero post-state (rather than leaving a dust debt behind).
        deal(USDC, alice, IERC20(USDC).balanceOf(alice) + ORIGINATION_FEE);
        vm.startPrank(alice);
        IERC20(USDC).approve(account, BORROW_AMOUNT);
        BaseLendingFacet(account).pay(BORROW_AMOUNT);
        vm.stopPrank();

        assertEq(
            BaseCollateralFacet(account).getTotalDebt(),
            0,
            "debt cleared after full repay"
        );
        assertEq(
            _lendingVault.activeAssets(),
            0,
            "vault.activeAssets reset after repay"
        );

        // Pull the veNFT back out. removeCollateral has the same access gate
        // as borrow, so we route through PortfolioManager.multicall again.
        bytes[] memory cd2 = new bytes[](1);
        cd2[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, HOLDER_TOKEN_A);
        address[] memory facs2 = new address[](1);
        facs2[0] = _testFactory;

        vm.prank(alice);
        pm.multicall(cd2, facs2);

        assertEq(
            IERC721(VE_HYDREX).ownerOf(HOLDER_TOKEN_A),
            alice,
            "veHYDX returned to alice on removeCollateral"
        );
        assertEq(
            BaseCollateralFacet(account).getTotalLockedCollateral(),
            0,
            "tracked collateral cleared after removeCollateral"
        );
    }

}
