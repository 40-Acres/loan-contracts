// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Facets under test
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";

// Infrastructure
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisGauge} from "../../mocks/MockYieldBasisGauge.sol";

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// LendingVault (replaces mock lending pool)
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

/**
 * @title YieldBasisBtcE2ETest
 * @dev End-to-end integration test for the YieldBasis BTC portfolio account system.
 *
 * Tests the full lifecycle:
 *   deposit ybBTC (auto-tracks collateral) -> borrow -> claim rewards ->
 *   fail to withdraw while indebted -> repay -> withdraw (auto-removes collateral)
 *
 * Architecture: YieldBasisLpFacet now implements ICollateralFacet directly.
 * deposit() calls ERC4626CollateralManager.addCollateral() and
 * withdraw() calls ERC4626CollateralManager.removeCollateral().
 * No separate ERC4626CollateralFacet is needed on the diamond.
 */
contract YieldBasisBtcE2ETest is Test {
    // Facets
    YieldBasisLpFacet public _ybBtcFacet;
    YieldBasisLpClaimingFacet public _ybBtcClaimingFacet;
    ERC4626LendingFacet public _erc4626LendingFacet;

    // Infrastructure
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;
    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;

    // Mock contracts
    MockERC20 public _ybBtc;       // underlying LP token (8 decimals like BTC)
    MockERC20 public _usdc;        // lending asset (8 decimals)
    MockERC20 public _ybToken;     // YB reward token (18 decimals)
    MockYieldBasisGauge public _gauge;
    LendingVault public _lendingVault;

    // Actors
    address public _user = address(0x40ac2e);
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    // Portfolio account (diamond proxy) for user
    address public _portfolioAccount;

    // Test amounts
    uint256 constant DEPOSIT_AMOUNT = 10e8;     // 10 ybBTC (8 decimals)
    uint256 constant VAULT_LIQUIDITY = 100_000e8; // 100k USDC-equivalent in vault

    function setUp() public {
        vm.startPrank(_owner);

        // --- Deploy portfolio manager and factory ---
        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-btc-e2e-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // --- Deploy config contracts ---
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (_portfolioFactoryConfig, , _loanConfig, ) = configDeployer.deploy(address(_portfolioFactory), _owner);

        // --- Deploy mock tokens ---
        _ybBtc = new MockERC20("ybBTC", "ybBTC", 8);
        _usdc = new MockERC20("USDC", "USDC", 8);
        _ybToken = new MockERC20("YieldBasis", "YB", 18);

        // --- Deploy mock gauge ---
        _gauge = new MockYieldBasisGauge(address(_ybBtc));

        // --- Deploy LendingVault behind ERC1967Proxy ---
        LendingVault lendingVaultImpl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(_usdc),              // asset
            address(_portfolioFactory),  // portfolioFactory
            _owner,                      // owner
            "Lending Vault",             // name
            "lVAULT",                    // symbol
            8000,                        // maxUtilizationBps (80%)
            80                           // originationFeeBps (0.8% for E2E)
        );
        ERC1967Proxy lendingVaultProxy = new ERC1967Proxy(address(lendingVaultImpl), initData);
        _lendingVault = LendingVault(address(lendingVaultProxy));

        // Fund lending vault with USDC liquidity (mint directly to vault)
        _usdc.mint(address(_lendingVault), VAULT_LIQUIDITY);

        // --- Configure ---
        _loanConfig.setMultiplier(7000); // 70% LTV
        _portfolioFactoryConfig.setLoanContract(address(_lendingVault));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        // --- Deploy and register YieldBasisLpFacet with ALL selectors (including ICollateralFacet) ---
        _ybBtcFacet = new YieldBasisLpFacet(address(_portfolioFactory), address(_gauge), address(_ybToken));
        {
            bytes4[] memory selectors = new bytes4[](9);
            selectors[0] = YieldBasisLpFacet.deposit.selector;
            selectors[1] = YieldBasisLpFacet.withdraw.selector;
            selectors[2] = YieldBasisLpFacet.unstake.selector;
            selectors[3] = YieldBasisLpFacet.restake.selector;
            selectors[4] = YieldBasisLpFacet.getStakingState.selector;
            // ICollateralFacet selectors — YieldBasisLpFacet implements ICollateralFacet
            selectors[5] = ICollateralFacet.enforceCollateralRequirements.selector;
            selectors[6] = ICollateralFacet.getTotalLockedCollateral.selector;
            selectors[7] = ICollateralFacet.getTotalDebt.selector;
            selectors[8] = ICollateralFacet.getMaxLoan.selector;
            _facetRegistry.registerFacet(address(_ybBtcFacet), selectors, "YieldBasisLpFacet");
        }

        // --- Deploy and register YieldBasisLpClaimingFacet ---
        _ybBtcClaimingFacet = new YieldBasisLpClaimingFacet(address(_portfolioFactory), address(_gauge));
        {
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
            selectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
            _facetRegistry.registerFacet(address(_ybBtcClaimingFacet), selectors, "YieldBasisLpClaimingFacet");
        }

        // --- Deploy and register ERC4626LendingFacet ---
        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        _erc4626LendingFacet = lendingDeployer.deploy(
            address(_portfolioFactory),
            address(_usdc),   // lending token
            address(_gauge)   // vault = gauge
        );

        // --- Set authorized caller ---
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        // --- Create portfolio account for user ---
        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // --- Fund user with ybBTC ---
        _ybBtc.mint(_user, DEPOSIT_AMOUNT * 10);
    }

    // ============ Helpers ============

    function _multicall(bytes[] memory calldatas) internal {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(_portfolioFactory);
        }
        _portfolioManager.multicall(calldatas, factories);
    }

    function _singleMulticall(bytes memory data) internal {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        _multicall(calldatas);
    }

    // ============ End-to-End Integration Test ============

    /**
     * @notice Full lifecycle test for YieldBasis BTC portfolio account system.
     *
     * Simplified flow now that YieldBasisLpFacet integrates ERC4626CollateralManager:
     * 1. User deposits ybBTC -> staked in gauge, collateral auto-tracked
     * 2. User borrows against collateral via ERC4626LendingFacet.borrow()
     * 3. YB rewards accumulate, claimed via YieldBasisLpClaimingFacet.claimGaugeRewards()
     * 4. User tries to withdraw while indebted -> FAIL (removeCollateral inside withdraw fails)
     * 5. User repays debt in full via ERC4626LendingFacet.pay()
     * 6. User withdraws all ybBTC -> collateral auto-removed, gauge shares returned
     */
    function testE2E_FullLifecycle() public {
        // ================================================================
        // STEP 1: User deposits ybBTC -> staked in gauge + collateral auto-tracked
        // ================================================================
        vm.startPrank(_user);
        _ybBtc.transfer(_portfolioAccount, DEPOSIT_AMOUNT);
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, DEPOSIT_AMOUNT));
        vm.stopPrank();

        // Verify: ybBTC is staked in gauge, portfolio account holds gauge shares
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT, "Step 1: staked amount should match deposit");
        assertEq(unstaked, 0, "Step 1: no unstaked ybBTC should remain");
        assertEq(_gauge.balanceOf(_portfolioAccount), DEPOSIT_AMOUNT, "Step 1: gauge shares should match deposit (1:1)");

        // Verify: collateral is auto-tracked (no separate addCollateral step needed)
        uint256 totalCollateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(totalCollateral, DEPOSIT_AMOUNT, "Step 1: collateral should be auto-tracked on deposit");

        (uint256 maxLoan, ) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        assertGt(maxLoan, 0, "Step 1: max loan should be > 0 with collateral");

        // ================================================================
        // STEP 2: User borrows against collateral
        // ================================================================
        uint256 borrowAmount = 5e8; // 5 USDC-equivalent (well within 70% LTV of 10 ybBTC)
        uint256 userUsdcBefore = _usdc.balanceOf(_user);

        vm.startPrank(_user);
        _singleMulticall(abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, borrowAmount));
        vm.stopPrank();

        // Verify: user received USDC (minus origination fee), debt is tracked
        uint256 originationFee = (borrowAmount * 80) / 10000; // 0.8%
        uint256 expectedNet = borrowAmount - originationFee;
        uint256 userUsdcAfter = _usdc.balanceOf(_user);
        assertEq(userUsdcAfter - userUsdcBefore, expectedNet, "Step 2: user should receive borrow amount minus fee");

        uint256 totalDebt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(totalDebt, borrowAmount, "Step 2: tracked debt should equal borrow amount");

        // ================================================================
        // STEP 3: YB rewards accumulate, claimed via claimGaugeRewards
        // ================================================================
        uint256 rewardAmount = 50e18; // 50 YB tokens
        _ybToken.mint(address(_gauge), rewardAmount);
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        // Preview rewards before claiming
        uint256 previewRewards = YieldBasisLpClaimingFacet(_portfolioAccount).previewGaugeRewards(address(_ybToken));
        assertEq(previewRewards, rewardAmount, "Step 3: preview should show full reward amount");

        // Claim rewards (authorized caller only)
        vm.prank(_authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(claimed, rewardAmount, "Step 3: claimed amount should match set rewards");
        assertEq(_ybToken.balanceOf(_portfolioAccount), rewardAmount, "Step 3: YB tokens should be on portfolio account");

        // After claiming, preview should be 0
        uint256 previewAfter = YieldBasisLpClaimingFacet(_portfolioAccount).previewGaugeRewards(address(_ybToken));
        assertEq(previewAfter, 0, "Step 3: preview should be 0 after claiming");

        // ================================================================
        // STEP 4: User tries to withdraw while indebted -> FAIL
        //         withdraw() calls removeCollateral first, which makes it
        //         undercollateralized, so enforceCollateralRequirements fails
        // ================================================================
        vm.startPrank(_user);
        vm.expectRevert(); // removeCollateral inside withdraw triggers undercollateralized check
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT_AMOUNT));
        vm.stopPrank();

        // Verify collateral unchanged
        totalCollateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(totalCollateral, DEPOSIT_AMOUNT, "Step 4: collateral should be unchanged after failed withdrawal");

        // ================================================================
        // STEP 5: User repays debt in full
        // ================================================================
        totalDebt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Step 5: should have outstanding debt before repayment");

        // User needs USDC to repay — mint it (simulating they earned/bought it)
        _usdc.mint(_user, totalDebt);

        // pay() can be called directly (not via multicall) — it pulls USDC from the caller
        vm.startPrank(_user);
        _usdc.approve(address(_portfolioAccount), totalDebt);
        ERC4626LendingFacet(_portfolioAccount).pay(totalDebt);
        vm.stopPrank();

        // Verify: debt is fully repaid
        totalDebt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(totalDebt, 0, "Step 5: debt should be 0 after full repayment");

        // enforceCollateralRequirements should pass cleanly
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Step 5: collateral requirements should pass with 0 debt");

        // ================================================================
        // STEP 6: User withdraws all ybBTC -> collateral auto-removed
        // ================================================================
        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT, "Step 6: all ybBTC should still be staked in gauge");

        uint256 userYbBtcBefore = _ybBtc.balanceOf(_user);

        vm.startPrank(_user);
        _singleMulticall(abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT_AMOUNT));
        vm.stopPrank();

        // Verify: user has all ybBTC back, gauge is empty
        uint256 userYbBtcAfter = _ybBtc.balanceOf(_user);
        assertEq(userYbBtcAfter - userYbBtcBefore, DEPOSIT_AMOUNT, "Step 6: user should have received all deposited ybBTC");

        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "Step 6: no ybBTC should be staked");
        assertEq(unstaked, 0, "Step 6: no ybBTC should be unstaked on account");

        // Verify: collateral auto-removed by withdraw
        totalCollateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(totalCollateral, 0, "Step 6: collateral should be 0 after withdrawal");

        // Verify: YB reward tokens are still on the portfolio account (from step 3)
        assertEq(_ybToken.balanceOf(_portfolioAccount), rewardAmount, "Step 6: YB rewards should still be on portfolio account");

        // Final state verification
        assertEq(ICollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Final: no debt");
        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0, "Final: no collateral");
        assertEq(_gauge.balanceOf(_portfolioAccount), 0, "Final: no gauge shares");
    }
}
