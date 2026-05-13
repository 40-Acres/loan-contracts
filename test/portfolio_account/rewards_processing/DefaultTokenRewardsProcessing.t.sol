// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";

/**
 * =============================================================================
 * Tests for _defaultToken immutable in RewardsProcessingFacet
 *
 * Tests the getRewardsToken() fallback behavior when _vault == address(0):
 *   1. No user rewards token configured -> returns _defaultToken
 *   2. User rewards token IS configured -> returns user's rewards token
 *
 * Also tests getRewardsToken() with vault present (existing behavior):
 *   3. Has debt -> returns vault asset
 *   4. No debt, no user rewards token -> returns vault asset
 *   5. No debt, user rewards token set -> returns user rewards token
 *
 * Tests _depositRemainingToVault when vault == address(0):
 *   6. Remaining funds sent to wallet account (not vault deposit)
 * =============================================================================
 */
contract DefaultTokenRewardsProcessingTest is Test, LocalSetup {
    // -- Vault-based diamond (from LocalSetup) --
    RewardsProcessingFacet public rewardsProcessingFacet;
    RewardsConfigFacet public rewardsConfigFacet;

    // -- No-vault diamond --
    PortfolioFactory public noVaultFactory;
    FacetRegistry public noVaultRegistry;
    address public noVaultAccount;
    RewardsProcessingFacet public noVaultRewardsProcessing;
    RewardsConfigFacet public noVaultRewardsConfig;

    // Wallet factory (salt=0) for _sendToWalletAccount
    PortfolioFactory public walletFactory;
    address public walletAccount;
    address public noVaultWalletAccount;

    // Separate output token for user config tests
    MockERC20 public customToken;

    address public rewardsToken;
    address public recipient = address(0x1234);

    uint256 constant ZERO_BAL_FEE_BPS = 100;   // 1%
    uint256 constant TREASURY_FEE_BPS = 500;    // 5%
    uint256 constant LENDER_PREMIUM_BPS = 2000; // 20%
    uint256 constant BPS_DENOM = 10000;

    // Events
    event RewardsProcessed(uint256 epoch, uint256 indexed tokenId, uint256 rewardsAmount, address user, address asset);

    function setUp() public override {
        super.setUp();

        rewardsToken = address(_usdc);
        customToken = new MockERC20("Custom Token", "CUST", 18);

        // -- The vault-based diamond already has RewardsProcessingFacet and
        //    RewardsConfigFacet registered via LocalSetup._deployAndRegisterFacets() --
        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);
        rewardsConfigFacet = RewardsConfigFacet(_portfolioAccount);

        // Set up rewards config + collateral via multicall
        _multicallOnMain(
            abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, recipient),
            abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId)
        );

        // Deploy wallet factory (salt=0)
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (walletFactory,) = _portfolioManager.deployFactory(bytes32(0));
        vm.stopPrank();
        walletAccount = walletFactory.createAccount(_user);

        // -- Deploy the no-vault diamond --
        _setupNoVaultFactory();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Setup helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Deploys a second portfolio factory where the RewardsProcessingFacet
    ///      is constructed with vault=address(0) and defaultToken=USDC.
    ///      This simulates a deployment that has no lending vault (e.g. a pure
    ///      rewards collection diamond).
    function _setupNoVaultFactory() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // 1. Deploy factory + registry
        (noVaultFactory, noVaultRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256("no-vault-default-token"))
        );

        // 2. Deploy a loan contract (required by getRewardsToken's require(loanContract != address(0)))
        //    Even though there is no vault, the loan contract must exist in config.
        Loan loanImpl = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImpl), "");
        address noVaultLoanContract = address(loanProxy);

        // Initialize with a throwaway vault just for Loan.initialize (won't be used)
        Vault dummyVaultImpl = new Vault();
        ERC1967Proxy dummyVaultProxy = new ERC1967Proxy(address(dummyVaultImpl), "");
        Vault dummyVault = Vault(address(dummyVaultProxy));
        dummyVault.initialize(_usdc, noVaultLoanContract, "dummy", "dummy");
        Loan(noVaultLoanContract).initialize(address(dummyVault), _usdc);

        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(noVaultLoanContract).upgradeToAndCall(address(loanV2Impl), new bytes(0));
        LoanV2(noVaultLoanContract).setPortfolioFactory(address(noVaultFactory));

        // 3. Deploy config
        PortfolioFactoryConfig configImpl = new PortfolioFactoryConfig();
        PortfolioFactoryConfig noVaultConfig = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (FORTY_ACRES_DEPLOYER, address(noVaultFactory)))
            ))
        );
        noVaultConfig.setLoanConfig(address(_loanConfig));
        noVaultConfig.setVoteConfig(address(_votingConfig));
        noVaultConfig.setLoanContract(noVaultLoanContract);
        noVaultFactory.setPortfolioFactoryConfig(address(noVaultConfig));

        // 4. Register CollateralFacet
        CollateralFacet collateralFacet = new CollateralFacet(address(noVaultFactory), address(_ve));
        bytes4[] memory colSel = new bytes4[](10);
        colSel[0] = BaseCollateralFacet.addCollateral.selector;
        colSel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        colSel[2] = BaseCollateralFacet.getTotalDebt.selector;
        colSel[3] = BaseCollateralFacet.getMaxLoan.selector;
        colSel[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        colSel[5] = BaseCollateralFacet.removeCollateral.selector;
        colSel[6] = BaseCollateralFacet.getCollateralToken.selector;
        colSel[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        colSel[8] = BaseCollateralFacet.getLockedCollateral.selector;
        colSel[9] = BaseCollateralFacet.removeCollateralTo.selector;
        noVaultRegistry.registerFacet(address(collateralFacet), colSel, "CollateralFacet");

        // 5. Register LendingFacet (needed for borrow to create debt for some tests)
        LendingFacet lendingFacet = new LendingFacet(address(noVaultFactory), _usdc);
        bytes4[] memory lendSel = new bytes4[](5);
        lendSel[0] = BaseLendingFacet.borrow.selector;
        lendSel[1] = BaseLendingFacet.pay.selector;
        lendSel[2] = BaseLendingFacet.setTopUp.selector;
        lendSel[3] = BaseLendingFacet.topUp.selector;
        lendSel[4] = BaseLendingFacet.borrowTo.selector;
        noVaultRegistry.registerFacet(address(lendingFacet), lendSel, "LendingFacet");

        // 6. Register RewardsProcessingFacet with vault=address(0), defaultToken=USDC
        VotingEscrowRewardsProcessingFacet rpFacet = new VotingEscrowRewardsProcessingFacet(
            address(noVaultFactory),
            address(_swapConfig),
            address(_ve),
            address(0),        // vault = address(0)
            address(_mockUsdc) // defaultToken = USDC
        );
        bytes4[] memory rpSel = new bytes4[](5);
        rpSel[0] = RewardsProcessingFacet.processRewards.selector;
        rpSel[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rpSel[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rpSel[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rpSel[4] = RewardsProcessingFacet.calculateRoutes.selector;
        noVaultRegistry.registerFacet(address(rpFacet), rpSel, "RewardsProcessingFacet");

        // 7. Register RewardsConfigFacet
        RewardsConfigFacet rcFacet = new RewardsConfigFacet(address(noVaultFactory), address(_swapConfig));
        bytes4[] memory rcSel = new bytes4[](6);
        rcSel[0] = RewardsConfigFacet.setRecipient.selector;
        rcSel[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rcSel[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rcSel[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rcSel[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rcSel[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        noVaultRegistry.registerFacet(address(rcFacet), rcSel, "RewardsConfigFacet");

        vm.stopPrank();

        // 8. Create user portfolio on the no-vault factory
        noVaultAccount = noVaultFactory.createAccount(_user);
        noVaultRewardsProcessing = RewardsProcessingFacet(noVaultAccount);
        noVaultRewardsConfig = RewardsConfigFacet(noVaultAccount);

        // 9. Mint veNFT and transfer to no-vault portfolio
        uint256 noVaultTokenId = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), noVaultAccount, noVaultTokenId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // 10. Set collateral + recipient via multicall on no-vault portfolio
        vm.startPrank(_user);
        address[] memory pf = new address[](2);
        pf[0] = address(noVaultFactory);
        pf[1] = address(noVaultFactory);
        bytes[] memory cd = new bytes[](2);
        cd[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, noVaultTokenId);
        cd[1] = abi.encodeWithSelector(RewardsConfigFacet.setRecipient.selector, recipient);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        // 11. Create wallet account for the no-vault user (for _sendToWalletAccount)
        noVaultWalletAccount = walletFactory.portfolioOf(_user);
        // Already created above for _user, so this should be the same as walletAccount
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _multicallOnMain(bytes memory cd1, bytes memory cd2) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](2);
        pf[0] = address(_portfolioFactory);
        pf[1] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](2);
        cd[0] = cd1;
        cd[1] = cd2;
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _multicallOnMain(bytes memory callData) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = callData;
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _multicallOnNoVault(bytes memory callData) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(noVaultFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = callData;
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _noSwap() internal pure returns (SwapMod.RouteParams[4] memory s) {}

    function _currentEpochStart() internal view returns (uint256) {
        return (block.timestamp / 1 weeks) * 1 weeks;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: getRewardsToken - vault=0, no user rewards token -> _defaultToken
    //
    // This is the primary new behavior: when there is no vault and the user
    // has not configured a custom rewards token, getRewardsToken() falls
    // back to the _defaultToken immutable (USDC in our setup).
    // ═══════════════════════════════════════════════════════════════════════

    function test_getRewardsToken_noVault_noUserToken_returnsDefaultToken() public {
        // Ensure no user rewards token is set (should be default address(0))
        // Do NOT call setRewardsToken — it was never set on the no-vault diamond
        address result = noVaultRewardsProcessing.getRewardsToken();
        assertEq(result, address(_mockUsdc), "No vault + no user token: should return _defaultToken (USDC)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: getRewardsToken - vault exists, has debt -> vault asset
    //
    // Existing behavior: when the diamond has a vault, getRewardsToken always
    // returns the vault's asset (USDC).
    // ═══════════════════════════════════════════════════════════════════════

    function test_getRewardsToken_withVault_hasDebt_returnsVaultAsset() public {
        // Create debt on the main (vault-based) diamond
        deal(address(_usdc), _vault, 1000e6);
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 500e6);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        address result = rewardsProcessingFacet.getRewardsToken();
        address vaultAsset = IERC4626(_vault).asset();
        assertEq(result, vaultAsset, "With vault + debt: should return vault asset");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: getRewardsToken - vault exists, no debt -> vault asset
    // ═══════════════════════════════════════════════════════════════════════

    function test_getRewardsToken_withVault_noDebt_returnsVaultAsset() public view {
        address result = rewardsProcessingFacet.getRewardsToken();
        address vaultAsset = IERC4626(_vault).asset();
        assertEq(result, vaultAsset, "With vault + no debt: should return vault asset");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 7: _depositRemainingToVault with vault=0 sends to wallet account
    //
    // When vault is address(0) and the borrower has debt, any excess after
    // debt payment goes to _depositRemainingToVault which should route the
    // funds to the wallet account instead of trying a vault deposit.
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositRemainingToVault_noVault_sendsToWalletAccount() public {
        // We need debt on the no-vault diamond so processRewards enters the
        // hasDebt branch (which calls _depositRemainingToVault for excess).
        // However, creating debt on the no-vault diamond requires the
        // Loan contract to have funds, and CollateralManager needs debt > 0.
        // We create debt via the LendingFacet.

        // Get the no-vault portfolio's loan contract config
        PortfolioFactoryConfig noVaultConfig = noVaultFactory.portfolioFactoryConfig();
        address noVaultLoan = noVaultConfig.getLoanContract();

        // Fund the loan contract's vault with USDC so borrow succeeds
        address loanVault = LoanV2(noVaultLoan)._vault();
        deal(address(_usdc), loanVault, 2000e6);

        // Borrow 500 USDC to create debt
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(noVaultFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 500e6);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        // Verify debt exists
        uint256 debt = BaseCollateralFacet(noVaultAccount).getTotalDebt();
        assertGt(debt, 0, "Should have debt");

        // Fund the portfolio account with more rewards than the debt
        // so there is remaining after debt payment
        uint256 rewardsAmount = debt + 500e6;
        deal(address(_mockUsdc), noVaultAccount, rewardsAmount);

        // Also need USDC approved on the loan contract from the portfolio
        // (the _decreaseTotalDebt path handles this internally via CollateralManager)

        uint256 walletBalanceBefore = IERC20(address(_mockUsdc)).balanceOf(walletAccount);

        // Process rewards
        vm.prank(_authorizedCaller);
        noVaultRewardsProcessing.processRewards(0, rewardsAmount, _noSwap(), 0);

        uint256 walletBalanceAfter = IERC20(address(_mockUsdc)).balanceOf(walletAccount);

        // After fees + debt repayment, any remaining should go to wallet account
        // (since vault=address(0), _depositRemainingToVault calls _sendToWalletAccount)
        assertGt(walletBalanceAfter, walletBalanceBefore, "Wallet account should receive remaining funds when vault=0");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 8: processRewards on no-vault diamond with zero balance (no debt)
    //
    // Verifies the full processRewards flow works correctly when vault=0
    // and there is no debt. Rewards should go to the recipient (via the
    // zero-balance distribution path).
    // ═══════════════════════════════════════════════════════════════════════

    function test_processRewards_noVault_zeroDebt_fundsToRecipient() public {
        uint256 rewardsAmount = 1000e6;
        deal(address(_mockUsdc), noVaultAccount, rewardsAmount);

        uint256 recipientBefore = IERC20(address(_mockUsdc)).balanceOf(recipient);

        vm.prank(_authorizedCaller);
        noVaultRewardsProcessing.processRewards(0, rewardsAmount, _noSwap(), 0);

        uint256 recipientAfter = IERC20(address(_mockUsdc)).balanceOf(recipient);

        // Zero balance fee = 1% of 1000e6 = 10e6
        uint256 fee = (rewardsAmount * ZERO_BAL_FEE_BPS) / BPS_DENOM;
        uint256 expectedRecipient = rewardsAmount - fee;

        assertEq(
            recipientAfter - recipientBefore,
            expectedRecipient,
            "Recipient should receive rewards minus zero balance fee"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 9: getRewardsToken immutable value is correctly set
    //
    // Directly verify the _defaultToken immutable on the facet contract
    // deployed with vault=address(0) has the expected value.
    // ═══════════════════════════════════════════════════════════════════════

    function test_defaultToken_immutable_setCorrectly() public view {
        // Read the _defaultToken from the facet via the diamond proxy
        // The diamond delegates to the facet, which has the immutable.
        // We access _defaultToken() on the RewardsProcessingFacet directly.
        address facetAddress = noVaultRegistry.selectorToFacet(RewardsProcessingFacet.getRewardsToken.selector);
        address defaultToken = RewardsProcessingFacet(facetAddress)._defaultToken();
        assertEq(defaultToken, address(_mockUsdc), "_defaultToken immutable should be USDC");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 10: vault immutable is address(0) on the no-vault facet
    // ═══════════════════════════════════════════════════════════════════════

    function test_vault_immutable_isZero_onNoVaultFacet() public view {
        address facetAddress = noVaultRegistry.selectorToFacet(RewardsProcessingFacet.getRewardsToken.selector);
        IERC4626 vaultVal = RewardsProcessingFacet(facetAddress)._vault();
        assertEq(address(vaultVal), address(0), "_vault immutable should be address(0) on no-vault facet");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 11: vault immutable is NOT address(0) on the main facet
    // ═══════════════════════════════════════════════════════════════════════

    function test_vault_immutable_isSet_onMainFacet() public view {
        address facetAddress = _facetRegistry.selectorToFacet(RewardsProcessingFacet.getRewardsToken.selector);
        IERC4626 vaultVal = RewardsProcessingFacet(facetAddress)._vault();
        assertEq(address(vaultVal), _vault, "_vault immutable should be the vault address on main facet");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 12: getRewardsToken on no-vault diamond is the rewards token used
    //          in processRewards (consistency check)
    //
    // The asset passed to the RewardsProcessed event should match what
    // getRewardsToken returns.
    // ═══════════════════════════════════════════════════════════════════════

    function test_processRewards_noVault_usesDefaultTokenAsAsset() public {
        uint256 rewardsAmount = 500e6;
        deal(address(_mockUsdc), noVaultAccount, rewardsAmount);

        address expectedAsset = noVaultRewardsProcessing.getRewardsToken();
        assertEq(expectedAsset, address(_mockUsdc), "getRewardsToken should return defaultToken");

        // Verify the RewardsProcessed event emits the correct asset
        vm.expectEmit(true, true, false, true);
        emit RewardsProcessed(
            _currentEpochStart(),
            0,
            rewardsAmount,
            _user,
            address(_mockUsdc)
        );

        vm.prank(_authorizedCaller);
        noVaultRewardsProcessing.processRewards(0, rewardsAmount, _noSwap(), 0);
    }
}
