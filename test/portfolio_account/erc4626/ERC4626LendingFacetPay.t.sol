// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * ERC4626LendingFacetPay
 *
 * Bug under test (current code)
 * -----------------------------
 * `ERC4626LendingFacet.pay(amount)` internally caps `amount` to `totalDebt`
 * before pulling funds and before computing the manager-level excess. The
 * function returns ONLY the post-pull `excess` from `decreaseTotalDebt`. When
 * a caller passes `amount > totalDebt`, the pre-cap delta
 * (`requestedAmount - totalDebt`) is silently dropped from the return value.
 *
 * Why this matters
 * ----------------
 * `RewardsProcessingFacet._payDebtToTarget` (and any other consumer that
 * computes `amountPaid = amountToPay - excess`) over-credits the amount
 * actually paid by exactly the pre-cap delta. Downstream accounting (zero
 * balance fees, remainder forwarding) drifts.
 *
 * What this reproducer asserts
 * ----------------------------
 * Direct-call to `ERC4626LendingFacet(portfolio).pay(100e6)` when debt is
 * 30e6 must:
 *   - return 70e6 (requestedAmount - actuallyPaid)
 *   - pull only 30e6 from the caller
 *   - zero out portfolio debt
 *   - emit Paid(30e6, caller)
 *
 * On the current (buggy) code, the function returns 0 instead of 70e6.
 *
 * Setup harness mirrors ERC4626LendingFacetTopUp.t.sol so the diamond, configs,
 * mock collateral vault, and lending vault wiring are identical.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";
import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployERC4626PortfolioFactoryConfig} from "../../../script/portfolio_account/DeployERC4626PortfolioFactoryConfig.s.sol";
import {ERC4626PortfolioFactoryConfig} from "../../../src/facets/account/erc4626/ERC4626PortfolioFactoryConfig.sol";
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
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC4626LendingFacetPayTest is Test {
    ERC4626CollateralFacet public _collateralFacet;
    ERC4626LendingFacet public _lendingFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    SwapConfig public _swapConfig;

    MockERC20 public _underlyingAsset;
    MockERC4626 public _mockVault;

    address public _loanContract;
    address public _lendingVault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _payer = address(0xBADADD);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 constant INITIAL_DEPOSIT = 1000e6;
    uint256 constant SETUP_FUND_BLOCK = 100;
    uint256 constant BORROW_AMOUNT = 30e6;
    uint256 constant OVERPAY_AMOUNT = 100e6;

    event Paid(uint256 amount, address indexed owner);

    function setUp() public virtual {
        vm.startPrank(_owner);

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory factory, FacetRegistry registry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-pay-test")))
        );
        _portfolioFactory = factory;
        _facetRegistry = registry;

        DeployPortfolioFactoryConfig configDeployer = new DeployERC4626PortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy(address(_portfolioFactory), _owner);

        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        _mockVault = new MockERC4626(address(_underlyingAsset), "Mock Collateral Vault", "mCVAULT", 6);

        _setupLendingInfrastructure();

        DeployERC4626CollateralFacet collatDeployer = new DeployERC4626CollateralFacet();
        _collateralFacet = collatDeployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        _lendingFacet = lendingDeployer.deploy(address(_portfolioFactory), address(_underlyingAsset), address(_mockVault));

        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000);
        _loanConfig.setLtv(7000);
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioFactoryConfig.setLoanContract(_loanContract);
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));
        ERC4626PortfolioFactoryConfig(address(_portfolioFactoryConfig)).setCollateralVault(address(_mockVault));

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Fund vault, then settle one block so it counts toward borrow capacity.
        vm.roll(SETUP_FUND_BLOCK);
        _underlyingAsset.mint(address(this), 10_000e6);
        _underlyingAsset.approve(_lendingVault, 10_000e6);
        DynamicFeesVault(payable(_lendingVault)).deposit(10_000e6, address(this));
        vm.roll(SETUP_FUND_BLOCK + 1);
    }

    function _setupLendingInfrastructure() internal {
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(_underlyingAsset),
            "ERC4626 Lending Vault",
            "lVAULT",
            address(_portfolioFactory),
            address(this),
            uint256(0)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        DynamicFeesVault dynamicVault = DynamicFeesVault(address(vaultProxy));
        _loanContract = address(dynamicVault);
        _lendingVault = address(dynamicVault);
        dynamicVault.transferOwnership(_owner);
        dynamicVault.acceptOwnership();
    }

    // ------------------------ helpers ------------------------

    function _stageShares(uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(_user);
        _underlyingAsset.mint(_user, assets);
        _underlyingAsset.approve(address(_mockVault), assets);
        shares = _mockVault.deposit(assets, _user);
        _mockVault.transfer(_portfolioAccount, shares);
        vm.stopPrank();
    }

    function _addCollateral(uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();
    }

    function _borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory facs = new address[](1);
        facs[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(data, facs);
        vm.stopPrank();
    }

    // ============================================================
    // BUG REPRO: pay() must return requestedAmount - actuallyPaid when capped
    // ============================================================

    /// @notice Reproduces the bug: when pay() is called with amount > totalDebt,
    /// the return value should equal `requestedAmount - actuallyPaid` so that
    /// consumers can derive `amountPaid = amountToPay - excess` correctly.
    /// Current code returns only the post-pull manager excess (typically 0),
    /// which means consumers over-credit the amount paid by exactly the
    /// pre-cap delta (requestedAmount - totalDebt).
    function test_pay_overpaymentAmount_returnsPrecapDelta() public {
        // 1) Establish 30e6 of debt on the portfolio.
        uint256 shares = _stageShares(INITIAL_DEPOSIT);
        _addCollateral(shares);
        _borrowViaMulticall(BORROW_AMOUNT);

        uint256 debtBefore = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "preconditions: debt == 30e6");

        // 2) Fund payer with enough to overpay (100e6) and approve the facet.
        _underlyingAsset.mint(_payer, OVERPAY_AMOUNT);
        vm.prank(_payer);
        _underlyingAsset.approve(_portfolioAccount, OVERPAY_AMOUNT);

        uint256 payerBalBefore = _underlyingAsset.balanceOf(_payer);

        // 3) Expect Paid event with amount == 30e6 (actually paid), not 100e6.
        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit Paid(BORROW_AMOUNT, _payer);

        // 4) Direct call to pay() with overpayment.
        vm.prank(_payer);
        uint256 excess = ERC4626LendingFacet(_portfolioAccount).pay(OVERPAY_AMOUNT);

        // 5) Core bug assertion: return value must reflect the dropped overage.
        //    Current buggy code returns ~0 here; fix returns 70e6.
        assertEq(excess, OVERPAY_AMOUNT - BORROW_AMOUNT, "pay() must return requestedAmount - actuallyPaid (70e6)");

        // 6) Payer balance must drop by EXACTLY the actual debt paid.
        uint256 payerBalAfter = _underlyingAsset.balanceOf(_payer);
        assertEq(payerBalBefore - payerBalAfter, BORROW_AMOUNT, "payer net out == actual debt paid (30e6)");

        // 7) Debt must be zero.
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "debt fully paid");
    }
}
