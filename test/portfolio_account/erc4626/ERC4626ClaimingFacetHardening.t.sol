// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * ERC4626ClaimingFacet Hardening Tests
 * ==========================================================================
 *
 * Covers Items 1 + 2 of the ERC4626 hardening port from YieldBasis:
 *
 *   1. Reentrancy guard
 *      - claimVaultYield is `nonReentrant` against the shared lending slot
 *        keccak256("fortyacres.lending.reentrancy"). A malicious vault that
 *        re-enters during `redeem` must be rejected, including cross-function
 *        reentry into the lending facet's `pay`.
 *
 *   2. Slippage floor
 *      - claimVaultYield(minAssetsPerShare):
 *          require minAssetsPerShare > 0      ("Zero slippage floor")
 *          require assetsReceived >= minAssetsOut, where
 *              minAssetsOut = sharesToRedeem * minAssetsPerShare / 1e18  ("Slippage")
 *          require assetsReceived * 100 >= previewRedeem(sharesToRedeem) * 85
 *              ("Slippage floor < 85%")
 *
 *      The caller-side floor is the primary defense — a vault that returns 0
 *      from previewRedeem AND 0 from redeem still gets rejected by the caller
 *      floor for any non-zero (sharesToRedeem * minAssetsPerShare / 1e18).
 * ==========================================================================
 */

import {Test, console} from "forge-std/Test.sol";
import {ERC4626ClaimingFacet} from "../../../src/facets/account/erc4626/ERC4626ClaimingFacet.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";
import {DeployERC4626ClaimingFacet} from "../../../script/portfolio_account/facets/DeployERC4626ClaimingFacet.s.sol";
import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockReentrantERC4626} from "../../mocks/MockReentrantERC4626.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC4626ClaimingFacetHardeningTest is Test {
    // ============ Test infrastructure ============

    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    SwapConfig public _swapConfig;

    MockERC20 public _underlyingAsset;
    MockReentrantERC4626 public _mockVault;
    ERC4626CollateralFacet public _erc4626CollateralFacet;
    ERC4626LendingFacet public _erc4626LendingFacet;
    ERC4626ClaimingFacet public _erc4626ClaimingFacet;

    address public _lendingVault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    uint256 constant YIELD_AMOUNT = 100e6;     // 100 USDC

    function setUp() public {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-claiming-hardening")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) =
            configDeployer.deploy(address(_portfolioFactory), _owner);

        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        _mockVault = new MockReentrantERC4626(address(_underlyingAsset), "Mock Vault", "mVAULT", 6);

        _setupLendingInfrastructure();

        DeployERC4626CollateralFacet collateralDeployer = new DeployERC4626CollateralFacet();
        _erc4626CollateralFacet = collateralDeployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        _erc4626LendingFacet = lendingDeployer.deploy(
            address(_portfolioFactory), address(_underlyingAsset), address(_mockVault)
        );

        DeployERC4626ClaimingFacet claimingDeployer = new DeployERC4626ClaimingFacet();
        _erc4626ClaimingFacet = claimingDeployer.deploy(address(_portfolioFactory), address(_mockVault));

        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000); // 70% LTV
        _loanConfig.setLtv(7000); // 70% LTV — like-to-like ERC4626 market uses LTV branch
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioFactoryConfig.setLoanContract(_lendingVault);
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);
        _underlyingAsset.mint(_user, INITIAL_DEPOSIT * 10);
        _underlyingAsset.mint(_lendingVault, 10000e6);
    }

    function _setupLendingInfrastructure() internal {
        LendingVault lendingVaultImpl = new LendingVault();
        ERC1967Proxy lendingVaultProxy = new ERC1967Proxy(address(lendingVaultImpl), "");
        LendingVault lendingVault = LendingVault(address(lendingVaultProxy));
        _lendingVault = address(lendingVault);

        lendingVault.initialize(
            address(_underlyingAsset),
            address(_portfolioFactory),
            _owner,
            "Lending Vault",
            "lVAULT",
            0
        );
    }

    // ============ Helpers ============

    function _depositCollateral(uint256 depositAmount) internal returns (uint256 shares) {
        vm.startPrank(_user);
        _underlyingAsset.approve(address(_mockVault), depositAmount);
        shares = _mockVault.deposit(depositAmount, _user);
        _mockVault.transfer(_portfolioAccount, shares);
        vm.stopPrank();

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _simulateYield(uint256 yieldAmount) internal {
        _underlyingAsset.mint(_owner, yieldAmount);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), yieldAmount);
        _mockVault.simulateYield(yieldAmount);
        vm.stopPrank();
    }

    function _setupYieldClaim() internal {
        _depositCollateral(INITIAL_DEPOSIT);
        _simulateYield(YIELD_AMOUNT);
    }

    // =====================================================================
    // ITEM 1 — Reentrancy guard
    // =====================================================================

    /**
     * @dev Sanity check: the benign claim path still succeeds when no reentry
     *      is armed. This prevents the reentrancy mock from yielding false
     *      positives in the negative tests below.
     */
    function test_claimVaultYield_benignVault_succeeds() public {
        _setupYieldClaim();

        uint256 portfolioAssetsBefore = _underlyingAsset.balanceOf(_portfolioAccount);

        vm.prank(_authorizedCaller);
        uint256 claimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);

        assertGt(claimed, 0, "Should have claimed some yield");
        // Bound: claim must be ~yield_amount (within 1%)
        assertApproxEqRel(claimed, YIELD_AMOUNT, 0.01e18, "Claim should approximate yield amount");

        uint256 portfolioAssetsAfter = _underlyingAsset.balanceOf(_portfolioAccount);
        assertEq(portfolioAssetsAfter - portfolioAssetsBefore, claimed, "Portfolio balance must increase by claim");
    }

    /**
     * @dev Cross-function: malicious vault re-enters claimVaultYield from inside
     *      redeem. The shared slot is locked, so reentry MUST revert with
     *      ReentrantCall, and the bubbled revert aborts the outer claim too.
     */
    function test_claimVaultYield_reentrancy_selfRecursion_reverts() public {
        _setupYieldClaim();

        bytes memory innerCall = abi.encodeWithSelector(
            ERC4626ClaimingFacet.claimVaultYield.selector,
            uint256(1)
        );
        _mockVault.arm(_portfolioAccount, innerCall);

        vm.prank(_authorizedCaller);
        // The malicious redeem bubbles up the inner ReentrantCall revert.
        vm.expectRevert(ERC4626ClaimingFacet.ReentrantCall.selector);
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);
    }

    /**
     * @dev Cross-function: malicious vault re-enters pay() from inside redeem.
     *      Since pay() shares the same lending slot, this MUST also revert
     *      with ReentrantCall. Proves the slot is shared across facets.
     */
    function test_claimVaultYield_reentrancy_intoPay_reverts() public {
        // Fund and borrow first so pay has something to do.
        _depositCollateral(INITIAL_DEPOSIT);
        // Borrow modestly within LTV
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, uint256(400e6));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Fund the portfolio so pay's transferFrom would succeed if not blocked.
        _underlyingAsset.mint(_portfolioAccount, 100e6);
        // Approve pay's transferFrom from portfolio account itself by giving the diamond
        // permission over its own balance. pay() calls transferFrom(from, address(this), amount)
        // where `from` is msg.sender (which during reentry will be the malicious vault).
        // Simpler: have the reentrant call originate from the malicious vault, which we
        // pre-fund and pre-approve.
        _underlyingAsset.mint(address(_mockVault), 100e6);
        vm.prank(address(_mockVault));
        _underlyingAsset.approve(_portfolioAccount, 100e6);

        // Now simulate yield so claim has work to do.
        _simulateYield(YIELD_AMOUNT);

        // Arm vault to call pay(50e6) on the diamond. msg.sender of that inner
        // call is the vault itself (because the vault makes the .call directly).
        bytes memory innerCall = abi.encodeWithSelector(
            ERC4626LendingFacet.pay.selector,
            uint256(50e6)
        );
        _mockVault.arm(_portfolioAccount, innerCall);

        vm.prank(_authorizedCaller);
        vm.expectRevert(ERC4626LendingFacet.ReentrantCall.selector);
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);
    }

    // =====================================================================
    // ITEM 2 — Slippage floor
    // =====================================================================

    /**
     * @dev minAssetsPerShare=0 must revert. This is the "no opt-out" rule —
     *      callers cannot request zero protection.
     */
    function test_claimVaultYield_zeroSlippage_reverts() public {
        _setupYieldClaim();
        vm.prank(_authorizedCaller);
        vm.expectRevert(bytes("Zero slippage floor"));
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(0);
    }

    /**
     * @dev Caller-floor exact boundary: minAssetsPerShare set so that
     *      minAssetsOut equals assetsReceived exactly. The require uses >=,
     *      so the equal case must succeed.
     *
     *      With a benign 1:1 vault and ~100 USDC of yield, the redeemable
     *      shares produce ~100 USDC. We compute assetsReceived first by
     *      static-calling previewRedeem on a snapshot, then use that to
     *      derive an exact boundary minAssetsPerShare.
     */
    function test_claimVaultYield_callerFloorExactBoundary_succeeds() public {
        _setupYieldClaim();

        // Read availability and compute the exact boundary mPerS such that
        // minAssetsOut == previewRedeem(sharesToRedeem). At benign 1:1 pricing
        // assetsReceived == previewRedeem, so this is the exact boundary.
        (uint256 yieldAssets, uint256 yieldShares) =
            ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertGt(yieldShares, 0, "Need yield shares for test");

        // assetsReceived expected ~= yieldAssets. minAssetsPerShare =
        // floor(assetsReceived * 1e6 / yieldShares) makes the floor equal to
        // floor(yieldShares * mPerS / 1e6) <= assetsReceived. Share unit is 1e6
        // (6-decimal shares), matching the facet's _shareUnit divisor.
        uint256 minAssetsPerShare = (yieldAssets * 1e6) / yieldShares;
        assertGt(minAssetsPerShare, 0, "boundary must be > 0");

        vm.prank(_authorizedCaller);
        uint256 claimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(minAssetsPerShare);
        assertGt(claimed, 0, "Should claim at exact boundary");
    }

    /**
     * @dev Caller-floor one wei too tight: bump minAssetsPerShare by enough
     *      that the resulting minAssetsOut exceeds assetsReceived by at least 1.
     *      Because the floor is computed as (sharesToRedeem * mPerS / 1e18),
     *      we must add at least ceil(1e18 / sharesToRedeem) to mPerS to
     *      guarantee a strictly greater minAssetsOut.
     */
    function test_claimVaultYield_callerFloorTooTight_reverts() public {
        _setupYieldClaim();

        (uint256 yieldAssets, uint256 yieldShares) =
            ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertGt(yieldShares, 0, "Need yield shares for test");

        uint256 baseline = (yieldAssets * 1e6) / yieldShares;
        // Add ceil(1e6 / yieldShares) + 1 to guarantee floor exceeds assetsReceived by >=1.
        // Share unit is 1e6 (6-decimal shares), matching the facet's _shareUnit divisor.
        uint256 stepUp = (1e6 + yieldShares - 1) / yieldShares + 1;
        uint256 tooTight = baseline + stepUp;

        vm.prank(_authorizedCaller);
        vm.expectRevert(bytes("Slippage"));
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(tooTight);
    }

    /**
     * @dev Decimals concrete check: 6-decimal vault/asset. minAssetsPerShare is
     *      asset-native wei per 1.0 WHOLE share, and a whole share is 1e6 share-wei
     *      here (6-decimal shares), so the floor divides by the 1e6 share unit.
     *      For our setup: 1000e6 deposit, 100e6 yield -- 100% gain on yield slice;
     *      vault price moves to 1100e6 / 1000e6 == 1.10 USDC per whole share.
     *
     *      minAssetsOut = sharesToRedeem * minAssetsPerShare / 1e6. Setting
     *      minAssetsPerShare = 1.05e6 (1.05 USDC per whole share) is below the
     *      ~1.10 actual, so the floor does not bind and the claim succeeds.
     *      Setting 1.20e6 (1.20 USDC per whole share, above 1.10) reverts -- see
     *      the tightFloor test below.
     */
    function test_claimVaultYield_decimals_concreteFloors() public {
        _setupYieldClaim();

        (, uint256 yieldShares) =
            ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertGt(yieldShares, 0, "Need yield shares");

        // Pass 1.05 USDC per whole share, 6d share unit => 1.05e6.
        // assetsReceived ~= yieldShares * 1.10 (price went 1.0 -> 1.10 USDC/share).
        // floor = yieldShares * 1.05e6 / 1e6 = yieldShares * 1.05.
        // 1.10 >= 1.05 -> passes.
        uint256 looseFloor = 1.05e6; // 1.05 USDC per whole share (6d share unit)
        // Reset state by creating new portfolio account would be tedious, so we
        // just exercise the "passes" case here. The "too tight" case was tested
        // above with the boundary computation. For decimals correctness, use
        // a separate fresh test below.
        vm.prank(_authorizedCaller);
        uint256 claimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(looseFloor);
        assertGt(claimed, 0, "Should claim with 1.05 USDC/share floor when actual is 1.10");
    }

    /**
     * @dev Decimals: same setup, but tightening floor to 1.20 USDC per whole
     *      share (6d share unit => 1.20e6) should revert with "Slippage" -- the
     *      actual is 1.10 USDC per whole share.
     */
    function test_claimVaultYield_decimals_tightFloor_reverts() public {
        _setupYieldClaim();

        // 1.20 USDC per whole share (6d share unit) -- strictly above the 1.10 actual.
        uint256 tightFloor = 1.20e6;

        vm.prank(_authorizedCaller);
        vm.expectRevert(bytes("Slippage"));
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(tightFloor);
    }

    /**
     * @dev Absolute 85% floor: vault returns 84% of previewRedeem.
     *      Caller floor passes (since assetsReceived > 0 and we use mPerS=1).
     *      Absolute floor must catch it: assetsReceived * 100 < previewedAssets * 85.
     */
    function test_claimVaultYield_absoluteFloor_84pct_reverts() public {
        _setupYieldClaim();

        // Configure vault to under-deliver vs its own previewRedeem.
        _mockVault.setRedeemScale(8400); // 84%

        vm.prank(_authorizedCaller);
        vm.expectRevert(bytes("Slippage floor < 85%"));
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);
    }

    /**
     * @dev Absolute 85% floor: vault returns 86% — passes the absolute floor.
     */
    function test_claimVaultYield_absoluteFloor_86pct_succeeds() public {
        _setupYieldClaim();

        _mockVault.setRedeemScale(8600); // 86%

        vm.prank(_authorizedCaller);
        uint256 claimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);
        assertGt(claimed, 0, "Should claim at 86% scale");
    }

    /**
     * @dev Absolute 85% floor exact-boundary: vault returns exactly 85% of
     *      previewRedeem. The check uses `>=`, so this must succeed.
     *
     *      Note: integer rounding in the scaling means assetsReceived is
     *      floor(previewedAssets * 85 / 100). The require check is
     *      `assetsReceived * 100 >= previewedAssets * 85`. With the truncation,
     *      assetsReceived * 100 = previewedAssets * 85 - (previewedAssets * 85 % 100)
     *      which can fall just under. We bump scale slightly above 85% to
     *      guarantee the boundary case passes; the strict-85%-with-rounding case
     *      is covered by the 84% revert (which definitively fails) and 86%
     *      pass (which definitively succeeds).
     */
    function test_claimVaultYield_absoluteFloor_85pct_passesNearBoundary() public {
        _setupYieldClaim();

        // 85.01% — slightly above to defeat truncation at the boundary.
        _mockVault.setRedeemScale(8501);

        vm.prank(_authorizedCaller);
        uint256 claimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(1);
        assertGt(claimed, 0, "Should pass at 85.01% scale");
    }

    /**
     * @dev Adversarial case: vault returns 0 from both previewRedeem and redeem.
     *      Under the conservative collateral valuation
     *      (_resolveCollateralValue = min(convertToAssets, previewRedeem)),
     *      getCollateral reports currentAssets = 0, so claimVaultYield reverts
     *      at the "No yield to harvest" upstream guard before reaching the
     *      slippage floors. The min() floor in ERC4626CollateralManager moved
     *      the adversarial-vault guard upstream from the caller-slippage floor.
     */
    function test_claimVaultYield_zeroPreview_revertsAtUpstreamGuard() public {
        _setupYieldClaim();

        // Force both previewRedeem and redeem to return 0.
        _mockVault.setForcePreviewRedeemZero(true);
        _mockVault.setForceRedeemReturn(0);

        // Under the conservative valuation, getAvailableYield reflects
        // previewRedeem and correctly reports zero yield available.
        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertEq(yieldAssets, 0, "Yield must be reported as zero when redeem path is broken");
        assertEq(yieldShares, 0, "Yield shares must be reported as zero when redeem path is broken");

        // claimVaultYield reverts at the upstream currentAssets > depositedAssets check.
        uint256 mPerS = 1e12;

        vm.prank(_authorizedCaller);
        vm.expectRevert(bytes("No yield to harvest"));
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(mPerS);
    }

    // =====================================================================
    // ITEM 3 -- Share-decimal scaling bug in caller-side floor (line 110)
    // =====================================================================
    //
    // The docstring defines minAssetsPerShare as asset-native wei per 1.0
    // WHOLE share. This vault is 6-decimal SHARES, so one whole share is
    // 1e6 share-wei, not 1e18. The correct floor divides by 10**vault.decimals()
    // (== 1e6 here). The code divides by a hardcoded 1e18, so the caller floor
    // collapses toward 0 and the primary slippage defense silently disappears.
    //
    // Vault state after _setupYieldClaim: 1100e6 assets / 1000e6 shares ~= 1.10
    // USDC per whole share. A floor of 1.2e6 (1.2 USDC per whole share) is ABOVE
    // the actual 1.10, so under the CORRECT per-whole-share semantic it MUST bind
    // and revert with "Slippage".

    /**
     * @dev Failing-first reproduction. Floor of 1.2 USDC per whole share is above
     *      the ~1.10 actual, so the correct semantic must revert with "Slippage".
     *      On the CURRENT broken code: 1.2e6 / 1e18 makes minAssetsOut ~= 0, so
     *      the floor never binds and the claim succeeds -- expectRevert is not
     *      satisfied and this test FAILS for the right reason.
     */
    function test_claimVaultYield_shareUnit_tightFloor_reverts() public {
        _setupYieldClaim();

        // 1.2 USDC per whole share, 6d share unit => 1.2e6. Above the 1.10 actual.
        uint256 tightFloor = 1.2e6;

        vm.prank(_authorizedCaller);
        vm.expectRevert(bytes("Slippage"));
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(tightFloor);
    }

    /**
     * @dev Companion regression guard. Floor of 1.0 USDC per whole share (6d
     *      share unit => 1.0e6) is BELOW the ~1.10 actual, so it must succeed.
     *      Passes on both broken and fixed code; pins the correct semantic.
     */
    function test_claimVaultYield_shareUnit_looseFloor_succeeds() public {
        _setupYieldClaim();

        // 1.0 USDC per whole share, 6d share unit => 1.0e6. Below the 1.10 actual.
        uint256 looseFloor = 1.0e6;

        vm.prank(_authorizedCaller);
        uint256 claimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(looseFloor);
        assertGt(claimed, 0, "Should claim with 1.0 USDC/whole-share floor when actual is 1.10");
    }
}
