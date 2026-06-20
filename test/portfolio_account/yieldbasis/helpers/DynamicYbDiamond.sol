// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {DynamicFeesVault} from "../../../../src/facets/account/vault/DynamicFeesVault.sol";
import {FeeCalculator} from "../../../../src/facets/account/vault/FeeCalculator.sol";

import {DynamicYieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisLpClaimingFacet} from "../../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpClaimingFacet.sol";
import {DynamicYieldBasisLpLendingFacet} from "../../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpLendingFacet.sol";

import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";

import {YbConfigDeployer} from "./YbConfigDeployer.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DynamicYbDiamond
/// @notice Shared harness builder for Dynamic YB LP facet tests. Each test
///         builds its own diamond because the gauge/LP/lendingPool are
///         immutable on each facet. The deploy hook constructs the three
///         user-facing facets (lp, claiming, lending) wired against the
///         supplied collateral primitives.
abstract contract DynamicYbDiamond is Test {
    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    DynamicFeesVault internal lendingVault;
    MockERC20 internal underlying;
    MockERC20 internal ybToken;

    DynamicYieldBasisLpFacet internal lpFacet;
    DynamicYieldBasisLpClaimingFacet internal claimingFacet;
    DynamicYieldBasisLpLendingFacet internal lendingFacet;

    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant VAULT_LIQ = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000;

    /// @dev Setup must be called by the inheriting contract's setUp().
    function _bootstrapTokens() internal {
        underlying = new MockERC20("WETH", "WETH", 18);
        ybToken = new MockERC20("YB", "YB", 18);
    }

    /// @dev Build the full diamond with the supplied gauge + lp + (optional
    ///      replacement lending pool). Pass `lendingPoolOverride = address(0)`
    ///      to use the standard LendingVault.
    function _build(address gauge, address lpToken, address lendingPoolOverride)
        internal
        returns (address portfolioAccount)
    {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("dyb-harness-", gauge, lpToken, lendingPoolOverride))
        );
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        // Production backing for the Dynamic YB collateral manager: a real
        // DynamicFeesVault (implements activeAssetsConservative natively). With
        // feeBps = 0 and no rewards deposited, totalAssets() and the conservative
        // read match what a funded LendingVault returned for these fixtures.
        DynamicFeesVault impl = new DynamicFeesVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                DynamicFeesVault.initialize,
                (address(underlying), "lvault", "lv", address(portfolioFactory), owner_, 0)
            )
        );
        lendingVault = DynamicFeesVault(address(proxy));
        lendingVault.setFeeCalculator(address(new FeeCalculator()));
        underlying.mint(address(lendingVault), VAULT_LIQ);

        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS);

        // The lending pool *seen by the facets* is what gets wired into
        // PortfolioFactoryConfig. If a test wants the facets to talk to a
        // mock pool, pass the mock here -- the facets are constructed against
        // it too, so lendingAsset() etc resolve consistently.
        address poolForFacets = lendingPoolOverride == address(0) ? address(lendingVault) : lendingPoolOverride;
        portfolioFactoryConfig.setLoanContract(poolForFacets);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // ---- Facets ----
        lpFacet = new DynamicYieldBasisLpFacet(
            address(portfolioFactory), gauge, address(ybToken), poolForFacets
        );
        {
            bytes4[] memory selectors = new bytes4[](9);
            selectors[0] = DynamicYieldBasisLpFacet.deposit.selector;
            selectors[1] = DynamicYieldBasisLpFacet.withdraw.selector;
            selectors[2] = DynamicYieldBasisLpFacet.setStakedMode.selector;
            selectors[3] = DynamicYieldBasisLpFacet.getStakingState.selector;
            selectors[4] = ICollateralFacet.enforceCollateralRequirements.selector;
            selectors[5] = ICollateralFacet.getTotalLockedCollateral.selector;
            selectors[6] = ICollateralFacet.getTotalDebt.selector;
            selectors[7] = ICollateralFacet.getMaxLoan.selector;
            selectors[8] = ICollateralFacet.getCollateralToken.selector;
            facetRegistry.registerFacet(address(lpFacet), selectors, "DYBLpFacet");
        }

        claimingFacet = new DynamicYieldBasisLpClaimingFacet(
            address(portfolioFactory), gauge, poolForFacets
        );
        {
            bytes4[] memory selectors = new bytes4[](5);
            selectors[0] = DynamicYieldBasisLpClaimingFacet.claimGaugeRewards.selector;
            selectors[1] = DynamicYieldBasisLpClaimingFacet.previewGaugeRewards.selector;
            selectors[2] = DynamicYieldBasisLpClaimingFacet.harvestLpFees.selector;
            selectors[3] = DynamicYieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
            selectors[4] = DynamicYieldBasisLpClaimingFacet.getDepositInfo.selector;
            facetRegistry.registerFacet(address(claimingFacet), selectors, "DYBClaimingFacet");
        }

        lendingFacet = new DynamicYieldBasisLpLendingFacet(
            address(portfolioFactory), poolForFacets, gauge
        );
        {
            // getMaxLoan / getTotalDebt are already exposed via ICollateralFacet
            // through the lp facet. Don't re-register them or selectors collide.
            bytes4[] memory selectors = new bytes4[](4);
            selectors[0] = DynamicYieldBasisLpLendingFacet.borrow.selector;
            selectors[1] = DynamicYieldBasisLpLendingFacet.pay.selector;
            selectors[2] = DynamicYieldBasisLpLendingFacet.setTopUp.selector;
            selectors[3] = DynamicYieldBasisLpLendingFacet.topUp.selector;
            facetRegistry.registerFacet(address(lendingFacet), selectors, "DYBLendingFacet");
        }

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);
    }

    function _depositVia(address portfolioAccount, MockERC20 lp, uint256 amount) internal {
        vm.startPrank(user);
        lp.approve(portfolioAccount, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _withdrawVia(address portfolioAccount, uint256 amount) internal {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.withdraw.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _setStakedMode(bool mode) internal {
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(mode);
    }
}
