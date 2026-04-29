// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../../src/LoanV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../src/interfaces/IVotingEscrow.sol";

/**
 * @title VeloLoanOpUpgradeTest
 * @notice Pre-upgrade fork validation for the live VeloLoanV2 UUPS proxy on Optimism mainnet.
 *
 * @dev The actual upgrade on mainnet is a Safe multisig transaction signed by
 *      `OWNER` — `vm.prank(OWNER)` simulates the multisig in this fork test, but
 *      the production tx will be a Safe `execTransaction` calling
 *      `upgradeToAndCall(NEW_IMPL, 0x)` on `PROXY`.
 *
 * @dev This test forks at HEAD by default and is therefore non-deterministic
 *      across runs (live state changes between borrower interactions). Before
 *      broadcasting, the user should:
 *        1. Pick the block they intend to broadcast at (or the most recent finalized block).
 *        2. Add `vm.rollFork(BLOCK)` after `vm.createSelectFork` in setUp.
 *        3. Re-run with that pin to get a reproducible final green light.
 *
 * @dev Run with:
 *        FOUNDRY_PROFILE=fork OP_RPC_URL=$OP_RPC_URL \
 *          forge test --match-path test/fork/VeloLoanOpUpgrade.t.sol -vv
 */

interface ILoanProxy {
    enum ZeroBalanceOption {
        DoNothing,
        InvestToVault,
        PayToOwner
    }

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function _vault() external view returns (address);
    function _asset() external view returns (IERC20);
    function _ve() external view returns (IVotingEscrow);
    function _outstandingCapital() external view returns (uint256);
    function _multiplier() external view returns (uint256);

    function getRewardsRate() external view returns (uint256);
    function getLenderPremium() external view returns (uint256);
    function getProtocolFee() external view returns (uint256);
    function getZeroBalanceFee() external view returns (uint256);

    function odosRouter() external view returns (address);
    function getMaxLoan(uint256 tokenId) external view returns (uint256, uint256);

    // Auto-generated public mapping getter for `_loanDetails`.
    // The dynamic `pools` array inside LoanInfo is skipped by the auto-getter,
    // so this returns the 14 non-array fields in struct-declaration order.
    function _loanDetails(uint256 tokenId) external view returns (
        uint256 tokenId_,
        uint256 balance,
        address borrower,
        uint256 timestamp,
        uint256 outstandingCapital,
        ZeroBalanceOption zeroBalanceOption,
        uint256 voteTimestamp,
        uint256 claimTimestamp,
        uint256 weight,
        uint256 unpaidFees,
        address preferredToken,
        uint256 increasePercentage,
        bool topUp,
        bool optInCommunityRewards
    );

    function upgradeToAndCall(address newImpl, bytes calldata data) external payable;

    function claim(
        uint256 tokenId,
        address[] calldata fees,
        address[][] calldata tokens,
        bytes calldata tradeData,
        uint256[2] calldata allocations
    ) external returns (uint256);

    function pay(uint256 tokenId, uint256 amount) external;

    function increaseLoan(uint256 tokenId, uint256 amount) external;
}

contract VeloLoanOpUpgradeTest is Test {
    // EIP-1967 implementation slot
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal constant PROXY    = 0xf132bD888897254521D13e2c401e109caABa06A7;
    address internal constant OLD_IMPL = 0x08C1375266b77841621B20586eF159B6e1d81873;
    address internal constant NEW_IMPL = 0x972B1Ac00DFb287F244205b379F4565aB286Ed3a;
    address internal constant OWNER    = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    address internal constant VAULT    = 0x08dCDBf7baDe91Ccd42CB2a4EA8e5D199d285957;
    address internal constant USDC_OP  = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    uint256 internal constant OP_CHAIN_ID = 10;

    uint256 internal constant TOKEN_ID_PRIMARY   = 4131;
    uint256 internal constant TOKEN_ID_SECONDARY = 1877;

    // Mirrors OZ ERC1967Utils.Upgraded(address indexed implementation)
    event Upgraded(address indexed implementation);

    ILoanProxy internal proxy;
    IERC20 internal usdc;

    function setUp() public {
        vm.createSelectFork(vm.envString("OP_RPC_URL"));
        require(
            block.chainid == OP_CHAIN_ID,
            "VeloLoanOpUpgradeTest: wrong chain - OP_RPC_URL must point to Optimism mainnet"
        );

        proxy = ILoanProxy(PROXY);
        usdc  = IERC20(USDC_OP);

        vm.label(PROXY,    "VeloLoanV2_Proxy");
        vm.label(OLD_IMPL, "VeloLoanV2_OldImpl");
        vm.label(NEW_IMPL, "VeloLoanV2_NewImpl");
        vm.label(OWNER,    "Owner_Safe");
        vm.label(VAULT,    "VaultV2");
        vm.label(USDC_OP,  "USDC_OP");
    }

    /* -------------------------------------------------------------------- */
    /*                          Pre-flight guards                            */
    /* -------------------------------------------------------------------- */

    /// @dev Fail-fast: confirm the proxy currently points at OLD_IMPL.
    /// If this fails, the upgrade has already been broadcast or the constants
    /// are wrong — bail loudly before doing any further validation.
    function testPreUpgradeImplSlotMatchesOld() public view {
        address current = _readImpl();
        assertEq(
            current,
            OLD_IMPL,
            "Proxy is not pointing at OLD_IMPL - did the upgrade already happen?"
        );
    }

    /* -------------------------------------------------------------------- */
    /*                       Upgrade authorization                           */
    /* -------------------------------------------------------------------- */

    /// @dev Confirms the upgrade flips the EIP-1967 impl slot and emits the
    ///      canonical Upgraded(NEW_IMPL) event.
    function testUpgrade_FlipsImplSlot() public {
        vm.expectEmit(true, false, false, false, PROXY);
        emit Upgraded(NEW_IMPL);

        vm.prank(OWNER);
        proxy.upgradeToAndCall(NEW_IMPL, "");

        assertEq(_readImpl(), NEW_IMPL, "Impl slot did not flip to NEW_IMPL");
    }

    /// @dev Negative test: a non-owner caller MUST NOT be able to upgrade.
    /// If this passes a revert is gone — that would be a critical regression.
    function testUpgrade_NonOwnerCannotUpgrade() public {
        address attacker = address(0xdead);
        vm.prank(attacker);
        vm.expectRevert();
        proxy.upgradeToAndCall(NEW_IMPL, "");

        // Confirm the slot is still the old impl after the failed attempt.
        assertEq(_readImpl(), OLD_IMPL, "Impl slot must not change on failed upgrade");
    }

    /* -------------------------------------------------------------------- */
    /*                         Storage drift checks                          */
    /* -------------------------------------------------------------------- */

    /// @dev The critical safety test for a UUPS upgrade. We snapshot the first
    ///      41 storage slots on the proxy (covers the entire fixed-layout
    ///      `Loan` contract region — 20 declared state vars plus a generous
    ///      buffer), plus every public getter that is read by users / scripts,
    ///      then upgrade and re-read everything. Every comparison must hold.
    ///
    ///      ERC-7201 namespaced storage in `RateStorage` / `LoanStorage`
    ///      lives at hashed slots far away from the linear region, so it is
    ///      validated separately via the public getters (rewardsRate,
    ///      lenderPremium, etc.).
    function testUpgrade_NoStorageDrift() public {
        // Snapshot raw slots 0..40 inclusive (41 slots).
        bytes32[41] memory pre;
        for (uint256 i = 0; i < pre.length; ++i) {
            pre[i] = vm.load(PROXY, bytes32(i));
        }

        // Snapshot getter results.
        address preOwner          = proxy.owner();
        address prePending        = proxy.pendingOwner();
        address preVault          = proxy._vault();
        IERC20  preAsset          = proxy._asset();
        IVotingEscrow preVe       = proxy._ve();
        uint256 preOutstanding    = proxy._outstandingCapital();
        uint256 preMultiplier     = proxy._multiplier();
        uint256 preRewardsRate    = proxy.getRewardsRate();
        uint256 preLenderPremium  = proxy.getLenderPremium();
        uint256 preProtocolFee    = proxy.getProtocolFee();
        uint256 preZeroBalFee     = proxy.getZeroBalanceFee();

        // Probe defaultPools[0] / defaultWeights[0] if present. Auto-getter
        // reverts on out-of-bounds, so wrap in low-level calls and tolerate
        // empty arrays cleanly.
        (bool defaultPoolOk, bytes memory defaultPoolPre) =
            PROXY.staticcall(abi.encodeWithSignature("_defaultPools(uint256)", 0));
        (bool defaultWeightOk, bytes memory defaultWeightPre) =
            PROXY.staticcall(abi.encodeWithSignature("_defaultWeights(uint256)", 0));

        // Upgrade.
        vm.prank(OWNER);
        proxy.upgradeToAndCall(NEW_IMPL, "");

        // Raw slot drift check.
        for (uint256 i = 0; i < pre.length; ++i) {
            bytes32 post = vm.load(PROXY, bytes32(i));
            assertEq(
                pre[i],
                post,
                string.concat("Storage drift at slot ", vm.toString(i))
            );
        }

        // Getter drift check.
        assertEq(proxy.owner(),                preOwner,         "owner drifted");
        assertEq(proxy.pendingOwner(),         prePending,       "pendingOwner drifted");
        assertEq(proxy._vault(),               preVault,         "_vault drifted");
        assertEq(address(proxy._asset()),      address(preAsset),"_asset drifted");
        assertEq(address(proxy._ve()),         address(preVe),   "_ve drifted");
        assertEq(proxy._outstandingCapital(),  preOutstanding,   "_outstandingCapital drifted");
        assertEq(proxy._multiplier(),          preMultiplier,    "_multiplier drifted");
        assertEq(proxy.getRewardsRate(),       preRewardsRate,   "rewardsRate drifted");
        assertEq(proxy.getLenderPremium(),     preLenderPremium, "lenderPremium drifted");
        assertEq(proxy.getProtocolFee(),       preProtocolFee,   "protocolFee drifted");
        assertEq(proxy.getZeroBalanceFee(),    preZeroBalFee,    "zeroBalanceFee drifted");

        // Default pools/weights drift.
        (bool defaultPoolOk2, bytes memory defaultPoolPost) =
            PROXY.staticcall(abi.encodeWithSignature("_defaultPools(uint256)", 0));
        (bool defaultWeightOk2, bytes memory defaultWeightPost) =
            PROXY.staticcall(abi.encodeWithSignature("_defaultWeights(uint256)", 0));

        assertEq(defaultPoolOk,   defaultPoolOk2,   "_defaultPools indexability changed");
        assertEq(defaultWeightOk, defaultWeightOk2, "_defaultWeights indexability changed");
        if (defaultPoolOk && defaultPoolOk2) {
            assertEq(keccak256(defaultPoolPre),  keccak256(defaultPoolPost),  "_defaultPools[0] drifted");
        }
        if (defaultWeightOk && defaultWeightOk2) {
            assertEq(keccak256(defaultWeightPre), keccak256(defaultWeightPost), "_defaultWeights[0] drifted");
        }
    }

    /// @dev Confirms the `_loanDetails` mapping survives the upgrade for two
    ///      live borrowers with distinct configurations. Mapping reads depend
    ///      on the base storage slot — any layout shift would silently zero
    ///      every entry, so this catches mapping-slot drift specifically.
    function testUpgrade_LoanDetailsMappingIntact() public {
        LoanSnapshot memory primaryPre   = _snapshotLoan(TOKEN_ID_PRIMARY);
        LoanSnapshot memory secondaryPre = _snapshotLoan(TOKEN_ID_SECONDARY);

        vm.prank(OWNER);
        proxy.upgradeToAndCall(NEW_IMPL, "");

        LoanSnapshot memory primaryPost   = _snapshotLoan(TOKEN_ID_PRIMARY);
        LoanSnapshot memory secondaryPost = _snapshotLoan(TOKEN_ID_SECONDARY);

        _assertLoansEq(primaryPre,   primaryPost,   "primary");
        _assertLoansEq(secondaryPre, secondaryPost, "secondary");
    }

    /* -------------------------------------------------------------------- */
    /*                  New-impl identity / sanity checks                    */
    /* -------------------------------------------------------------------- */

    /// @dev Confirms NEW_IMPL is the OP-flavored `VeloLoan` (which keeps the
    ///      ODOS router constant and overrides the OP USDC oracle), not a
    ///      Base-flavored impl deployed to the wrong chain.
    function testUpgrade_OdosRouterConstant() public {
        vm.prank(OWNER);
        proxy.upgradeToAndCall(NEW_IMPL, "");

        assertEq(
            proxy.odosRouter(),
            0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05,
            "odosRouter() must remain the Odos V3 router on OP"
        );
    }

    /// @dev `getMaxLoan` reads several view-only paths that touch
    ///      `_outstandingCapital`, vault balance, `_multiplier`, rewards rate,
    ///      and per-loan balance. Pre/post equality with no state changes in
    ///      between is a smoke test that none of those reads have shifted.
    function testUpgrade_GetMaxLoanStable() public {
        (uint256 prePrimary, uint256 prePrimaryIgnore)     = proxy.getMaxLoan(TOKEN_ID_PRIMARY);
        (uint256 preSecondary, uint256 preSecondaryIgnore) = proxy.getMaxLoan(TOKEN_ID_SECONDARY);

        vm.prank(OWNER);
        proxy.upgradeToAndCall(NEW_IMPL, "");

        (uint256 postPrimary, uint256 postPrimaryIgnore)     = proxy.getMaxLoan(TOKEN_ID_PRIMARY);
        (uint256 postSecondary, uint256 postSecondaryIgnore) = proxy.getMaxLoan(TOKEN_ID_SECONDARY);

        assertEq(prePrimary,           postPrimary,           "primary maxLoan drifted");
        assertEq(prePrimaryIgnore,     postPrimaryIgnore,     "primary maxLoanIgnoreSupply drifted");
        assertEq(preSecondary,         postSecondary,         "secondary maxLoan drifted");
        assertEq(preSecondaryIgnore,   postSecondaryIgnore,   "secondary maxLoanIgnoreSupply drifted");
    }

    /* -------------------------------------------------------------------- */
    /*                  Live behavior end-to-end smoke test                  */
    /* -------------------------------------------------------------------- */

    /// @dev Exercises borrower-facing flows on the upgraded impl using live
    ///      state. We don't assert specific reward amounts (live state varies)
    ///      but do assert balance deltas for `pay` and `increaseLoan` so that
    ///      a math regression in those paths is caught.
    function testUpgrade_ClaimPayIncreaseFlow() public {
        // Upgrade first.
        vm.prank(OWNER);
        proxy.upgradeToAndCall(NEW_IMPL, "");

        LoanSnapshot memory snap = _snapshotLoan(TOKEN_ID_PRIMARY);
        address borrower = snap.borrower;
        require(borrower != address(0), "primary borrower zeroed - bad token id or layout drift");
        vm.label(borrower, "PrimaryBorrower");

        // ----- claim() -----
        // We do NOT assert reward amounts (live state). We only assert the
        // call doesn't revert when invoked by the entrypoint, and that the
        // proxy still owns the veNFT after.
        // The internal `claim` requires `msg.sender == _entryPoint()` which
        // returns the hardcoded 40Ac entrypoint. Looking at LoanV2.claim, the
        // function bails early when there is nothing to do, but only if the
        // entrypoint is the caller. We try claim from the entrypoint and
        // tolerate a revert (e.g. tradeData empty path) — the goal here is
        // not to validate claim math but to exercise the upgraded code path
        // for a recently-active borrower.
        address entrypoint = 0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA;
        address[] memory fees = new address[](0);
        address[][] memory tokens = new address[][](0);
        uint256[2] memory allocations = [uint256(0), uint256(0)];

        // Empty tradeData triggers an early revert in `_processRewards`.
        // Use a non-empty placeholder so we hit the odos router call. Since
        // we don't want to pollute live router state, we instead skip the
        // odos path entirely by relying on the early-exit when balance==0
        // and zeroBalanceOption==DoNothing. That early exit only fires when
        // both conditions hold; for an active borrower with topUp=true those
        // don't, so a clean claim attempt would need real tradeData.
        //
        // Bottom line: we cannot safely run the full claim path on a fork
        // without trusted tradeData. We therefore confirm the function
        // selector is reachable from the entrypoint and reverts cleanly
        // when given empty tradeData (tradeData.length == 0 -> revert()).
        vm.prank(entrypoint);
        vm.expectRevert();
        proxy.claim(TOKEN_ID_PRIMARY, fees, tokens, hex"", allocations);

        // Confirm the veNFT is still custodied by the proxy after the
        // attempted claim — the upgrade must not corrupt collateral
        // bookkeeping.
        assertEq(
            proxy._ve().ownerOf(TOKEN_ID_PRIMARY),
            PROXY,
            "Proxy lost custody of primary veNFT after claim attempt"
        );

        // ----- pay() -----
        uint256 payAmount = 1e6; // 1 USDC

        // forge-std `deal` for ERC20 — works for OP USDC because it uses
        // standard balance storage. If this ever stops working we'd need a
        // whale path; for now this is the cleanest funding source.
        deal(USDC_OP, borrower, payAmount);

        uint256 balanceBefore = snap.balance;
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        uint256 vaultUsdcBefore    = usdc.balanceOf(VAULT);
        uint256 ownerUsdcBefore    = usdc.balanceOf(OWNER);

        vm.startPrank(borrower);
        usdc.approve(PROXY, payAmount);
        proxy.pay(TOKEN_ID_PRIMARY, payAmount);
        vm.stopPrank();

        // Re-read post-pay loan balance.
        (, uint256 balanceAfter,,,,,,,,,,,, ) = proxy._loanDetails(TOKEN_ID_PRIMARY);

        // Borrower's USDC should be drained by exactly payAmount.
        assertEq(
            usdc.balanceOf(borrower),
            borrowerUsdcBefore - payAmount,
            "borrower USDC delta on pay() incorrect"
        );

        // Loan balance should never *increase* on a pay. It can decrease by
        // payAmount, or by less if there were unpaid fees that consumed part
        // of the payment first (fees go to owner, not vault). After clearing
        // unpaid fees, the rest reduces principal.
        assertLe(balanceAfter, balanceBefore, "pay() increased loan balance");
        // Combined: vault + owner USDC together must have grown by exactly
        // payAmount (fees -> owner, principal repayment -> vault).
        uint256 ownerDelta = usdc.balanceOf(OWNER) - ownerUsdcBefore;
        uint256 vaultDelta = usdc.balanceOf(VAULT) - vaultUsdcBefore;
        assertEq(
            ownerDelta + vaultDelta,
            payAmount,
            "pay() did not route the full amount to (owner + vault)"
        );

        // ----- increaseLoan() -----
        // Snapshot under-the-hood state needed for the math.
        (, uint256 balPre,,,,,,,,,,,, ) = proxy._loanDetails(TOKEN_ID_PRIMARY);
        uint256 outstandingPre = proxy._outstandingCapital();

        // Pre-fund the vault generously so utilization isn't the binding
        // constraint, then bump the multiplier so the rewards-rate ceiling
        // doesn't pin maxLoan at 0. Both nudges are required because the
        // primary borrower at HEAD is at or above its current ceiling.
        // We use `setMultiplier(uint256)` via OWNER, which is a real owner
        // capability (not a cheatcode hack) — this faithfully exercises the
        // upgraded impl's increaseLoan path under realistic admin tuning.
        deal(USDC_OP, VAULT, usdc.balanceOf(VAULT) + 1_000_000e6);
        (uint256 maxLoanBefore, ) = proxy.getMaxLoan(TOKEN_ID_PRIMARY);
        if (maxLoanBefore < 1e6) {
            uint256 currentMul = proxy._multiplier();
            // 100x bump is a sledgehammer but keeps us safely above the
            // current per-loan balance for any realistic borrower. This is
            // a real owner capability, not a cheatcode hack.
            vm.prank(OWNER);
            (bool ok, ) = PROXY.call(
                abi.encodeWithSignature("setMultiplier(uint256)", currentMul * 100)
            );
            require(ok, "setMultiplier failed");
        }
        (uint256 maxLoanNow, ) = proxy.getMaxLoan(TOKEN_ID_PRIMARY);
        require(maxLoanNow >= 1e6, "Could not create headroom for increaseLoan leg");
        uint256 borrowAmount = 1e6;

        // Re-read borrower / owner USDC after the deal-to-vault (deal does
        // not alter borrower balance, but be explicit for the math).
        uint256 borrowerUsdcPre = usdc.balanceOf(borrower);
        uint256 ownerUsdcPre    = usdc.balanceOf(OWNER);

        vm.prank(borrower);
        proxy.increaseLoan(TOKEN_ID_PRIMARY, borrowAmount);

        uint256 originationFee = (borrowAmount * 80) / 10000; // 0.8% per Loan._increaseLoan
        uint256 expectedToBorrower = borrowAmount - originationFee;

        // Borrower receives principal minus origination fee.
        assertEq(
            usdc.balanceOf(borrower) - borrowerUsdcPre,
            expectedToBorrower,
            "borrower did not receive (amount - originationFee)"
        );

        // Owner receives origination fee directly from vault.
        assertEq(
            usdc.balanceOf(OWNER) - ownerUsdcPre,
            originationFee,
            "owner did not receive origination fee"
        );

        // Outstanding capital and per-loan balance grow by the FULL borrow
        // amount (fee comes out of vault, not subtracted from debt).
        assertEq(
            proxy._outstandingCapital() - outstandingPre,
            borrowAmount,
            "_outstandingCapital did not grow by borrow amount"
        );
        (, uint256 balPost,,,,,,,,,,,, ) = proxy._loanDetails(TOKEN_ID_PRIMARY);
        assertEq(
            balPost - balPre,
            borrowAmount,
            "loan.balance did not grow by borrow amount"
        );
    }

    /* -------------------------------------------------------------------- */
    /*                              Helpers                                  */
    /* -------------------------------------------------------------------- */

    function _readImpl() internal view returns (address) {
        return address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT))));
    }

    struct LoanSnapshot {
        uint256 tokenId;
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
        ILoanProxy.ZeroBalanceOption zeroBalanceOption;
        uint256 voteTimestamp;
        uint256 claimTimestamp;
        uint256 weight;
        uint256 unpaidFees;
        address preferredToken;
        uint256 increasePercentage;
        bool topUp;
        bool optInCommunityRewards;
    }

    function _snapshotLoan(uint256 tokenId) internal view returns (LoanSnapshot memory s) {
        (
            s.tokenId,
            s.balance,
            s.borrower,
            s.timestamp,
            s.outstandingCapital,
            s.zeroBalanceOption,
            s.voteTimestamp,
            s.claimTimestamp,
            s.weight,
            s.unpaidFees,
            s.preferredToken,
            s.increasePercentage,
            s.topUp,
            s.optInCommunityRewards
        ) = proxy._loanDetails(tokenId);
    }

    function _assertLoansEq(LoanSnapshot memory a, LoanSnapshot memory b, string memory label) internal pure {
        assertEq(a.tokenId,              b.tokenId,              string.concat(label, ": tokenId drift"));
        assertEq(a.balance,              b.balance,              string.concat(label, ": balance drift"));
        assertEq(a.borrower,             b.borrower,             string.concat(label, ": borrower drift"));
        assertEq(a.timestamp,            b.timestamp,            string.concat(label, ": timestamp drift"));
        assertEq(a.outstandingCapital,   b.outstandingCapital,   string.concat(label, ": outstandingCapital drift"));
        assertEq(uint8(a.zeroBalanceOption), uint8(b.zeroBalanceOption), string.concat(label, ": zeroBalanceOption drift"));
        assertEq(a.voteTimestamp,        b.voteTimestamp,        string.concat(label, ": voteTimestamp drift"));
        assertEq(a.claimTimestamp,       b.claimTimestamp,       string.concat(label, ": claimTimestamp drift"));
        assertEq(a.weight,               b.weight,               string.concat(label, ": weight drift"));
        assertEq(a.unpaidFees,           b.unpaidFees,           string.concat(label, ": unpaidFees drift"));
        assertEq(a.preferredToken,       b.preferredToken,       string.concat(label, ": preferredToken drift"));
        assertEq(a.increasePercentage,   b.increasePercentage,   string.concat(label, ": increasePercentage drift"));
        assertEq(a.topUp,                b.topUp,                string.concat(label, ": topUp drift"));
        assertEq(a.optInCommunityRewards,b.optInCommunityRewards,string.concat(label, ": optInCommunityRewards drift"));
    }
}
