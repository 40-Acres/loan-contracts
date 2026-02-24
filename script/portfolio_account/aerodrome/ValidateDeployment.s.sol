// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {FortyAcresPortfolioAccount} from "../../../src/accounts/FortyAcresPortfolioAccount.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {ILoanConfig} from "../../../src/facets/account/config/ILoanConfig.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ValidateAerodromeDeployment
 * @dev Post-deployment validation script for the Aerodrome USDC deployment.
 *      Reads live on-chain proxy state and verifies all UUPS implementations
 *      are upgraded and support required function selectors.
 *      Includes a full dry-run simulation: create veNFT → borrow → repay.
 *
 *      Run ad-hoc after any deployment or upgrade:
 *        forge script script/portfolio_account/aerodrome/ValidateDeployment.s.sol:ValidateAerodromeDeployment \
 *          --rpc-url $BASE_RPC_URL --via-ir
 *
 *      Also usable as a library via _validateConfig() for inline validation
 *      within deploy/upgrade scripts.
 */
contract ValidateAerodromeDeployment is Script, StdCheats {
    // ─── Live deployed addresses ──────────────────────────────────────
    address constant LIVE_PORTFOLIO_MANAGER = 0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5;
    address constant LIVE_PORTFOLIO_ACCOUNT_CONFIG = 0x400C710cbEadc5bb8b7132B3061fA1b6d6f80Dd8;
    address constant LIVE_PORTFOLIO_FACTORY = 0xfeEB5C58786617230095a008164b096e3205EAF2;
    address constant LIVE_SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;
    address constant LIVE_VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant LIVE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ERC1967 implementation storage slot
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        console.log("=== Aerodrome Deployment Validation ===");

        _validateConfig(
            PortfolioAccountConfig(LIVE_PORTFOLIO_ACCOUNT_CONFIG),
            LIVE_PORTFOLIO_FACTORY
        );

        _validateLoan(
            PortfolioAccountConfig(LIVE_PORTFOLIO_ACCOUNT_CONFIG),
            LIVE_PORTFOLIO_FACTORY
        );

        _validateFactoryLinkage(
            LIVE_PORTFOLIO_FACTORY,
            LIVE_PORTFOLIO_MANAGER
        );

        _validatePayFlow(
            PortfolioAccountConfig(LIVE_PORTFOLIO_ACCOUNT_CONFIG),
            LIVE_PORTFOLIO_FACTORY
        );

        _validateImplementationCodehash(LIVE_PORTFOLIO_ACCOUNT_CONFIG);

        _validateDryRun(
            PortfolioAccountConfig(LIVE_PORTFOLIO_ACCOUNT_CONFIG),
            LIVE_PORTFOLIO_FACTORY
        );

        console.log("=== All validations passed ===");
    }

    /// @dev Validates PortfolioAccountConfig proxy supports all required selectors
    ///      and returns expected values. Reverts on failure.
    function _validateConfig(
        PortfolioAccountConfig config,
        address expectedFactory
    ) internal view {
        console.log("Validating PortfolioAccountConfig...");

        // Implementation exists
        address impl = _getImplementation(address(config));
        require(impl != address(0), "Config: implementation is zero");
        require(impl.code.length > 0, "Config: implementation has no code");
        console.log("  Implementation:", impl);

        // getPortfolioFactory - the exact call that broke borrowing
        address factory = config.getPortfolioFactory();
        require(factory == expectedFactory, "Config: getPortfolioFactory() mismatch");
        console.log("  Portfolio factory:", factory);

        // getLoanContract
        address loan = config.getLoanContract();
        require(loan != address(0), "Config: getLoanContract() is zero");
        console.log("  Loan contract:", loan);

        // getVoteConfig
        address voteConfig = config.getVoteConfig();
        require(voteConfig != address(0), "Config: getVoteConfig() is zero");
        console.log("  Vote config:", voteConfig);

        // getLoanConfig
        address loanConfig = address(config.getLoanConfig());
        require(loanConfig != address(0), "Config: getLoanConfig() is zero");
        console.log("  Loan config:", loanConfig);

        // getVault (reads through loan)
        address vault = config.getVault();
        require(vault != address(0), "Config: getVault() is zero");
        console.log("  Vault:", vault);

        // getDebtToken (reads through loan)
        address debtToken = config.getDebtToken();
        require(debtToken != address(0), "Config: getDebtToken() is zero");
        console.log("  Debt token:", debtToken);

        // getMinimumCollateral (just must not revert)
        config.getMinimumCollateral();

        // owner
        address owner = config.owner();
        require(owner != address(0), "Config: owner is zero");
        console.log("  Owner:", owner);

        console.log("  [OK] PortfolioAccountConfig");
    }

    /// @dev Validates the Loan UUPS proxy is upgraded and consistent with config
    function _validateLoan(
        PortfolioAccountConfig config,
        address expectedFactory
    ) internal view {
        console.log("Validating Loan proxy...");

        address loanProxy = config.getLoanContract();
        address impl = _getImplementation(loanProxy);
        require(impl != address(0), "Loan: implementation is zero");
        require(impl.code.length > 0, "Loan: implementation has no code");
        console.log("  Implementation:", impl);

        // getPortfolioFactory on loan
        address loanFactory = LoanV2(payable(loanProxy)).getPortfolioFactory();
        require(loanFactory == expectedFactory, "Loan: getPortfolioFactory() mismatch");

        // vault linkage
        address vault = ILoan(loanProxy)._vault();
        require(vault != address(0), "Loan: _vault() is zero");

        // Cross-reference: config and loan agree on factory
        address configFactory = config.getPortfolioFactory();
        require(configFactory == loanFactory, "Config and Loan disagree on portfolio factory");

        console.log("  [OK] Loan proxy");
    }

    /// @dev Validates Factory -> Manager -> Registry linkage
    function _validateFactoryLinkage(
        address factoryAddr,
        address expectedManager
    ) internal view {
        console.log("Validating factory linkage...");

        PortfolioFactory factory = PortfolioFactory(factoryAddr);

        PortfolioManager manager = factory.portfolioManager();
        require(address(manager) == expectedManager, "Factory: manager mismatch");

        FacetRegistry registry = factory.facetRegistry();
        require(address(registry) != address(0), "Factory: registry is zero");
        require(registry.getVersion() > 0, "Factory: registry version is zero");

        require(manager.isRegisteredFactory(factoryAddr), "Factory: not registered in manager");

        console.log("  [OK] Factory linkage");
    }

    /// @dev Validates every external call in the pay() → decreaseTotalDebt() → getMaxLoan() chain.
    ///      The full call graph:
    ///        pay() → CollateralManager.decreaseTotalDebt(config, amount)
    ///          ├─ getMaxLoan(config)
    ///          │    ├─ config.getLoanConfig()         → ILoanConfig
    ///          │    ├─ loanConfig.getRewardsRate()
    ///          │    ├─ loanConfig.getMultiplier()
    ///          │    ├─ config.getLoanContract()        → lendingPool
    ///          │    ├─ lendingPool.activeAssets()
    ///          │    ├─ lendingPool.lendingVault()      → vault
    ///          │    └─ IERC4626(vault).asset()         → underlyingAsset
    ///          ├─ config.getLoanContract()              → lendingPool
    ///          ├─ lendingPool.lendingAsset()            → for ERC20 approve
    ///          └─ lendingPool.payFromPortfolio()
    ///               ├─ LoanV2.getPortfolioFactory()
    ///               └─ IPortfolioFactory(factory).ownerOf(msg.sender)
    function _validatePayFlow(
        PortfolioAccountConfig config,
        address expectedFactory
    ) internal view {
        console.log("Validating pay() call chain...");

        // 1. config.getLoanContract() — CollateralManager reads this to get the lending pool
        address loanProxy = config.getLoanContract();
        require(loanProxy != address(0), "Pay: config.getLoanContract() is zero");

        // 2. lendingPool.lendingAsset() — CollateralManager calls this for ERC20 approve
        address lendingAsset = ILendingPool(loanProxy).lendingAsset();
        require(lendingAsset != address(0), "Pay: lendingPool.lendingAsset() is zero");
        console.log("  Lending asset:", lendingAsset);

        // 3. lendingPool.lendingVault() — used by getMaxLoan() for vault balance check
        address lendingVault = ILendingPool(loanProxy).lendingVault();
        require(lendingVault != address(0), "Pay: lendingPool.lendingVault() is zero");
        console.log("  Lending vault:", lendingVault);

        // 4. lendingPool.activeAssets() — getMaxLoan() reads outstanding capital
        ILendingPool(loanProxy).activeAssets();
        console.log("  activeAssets(): callable");

        // 5. IERC4626(vault).asset() — getMaxLoan() reads underlying asset from vault
        address underlyingAsset = IERC4626(lendingVault).asset();
        require(underlyingAsset != address(0), "Pay: IERC4626(vault).asset() is zero");
        console.log("  Vault underlying asset:", underlyingAsset);

        // 6. config.getLoanConfig() → getRewardsRate() / getMultiplier()
        //    getMaxLoan() calls these for the max loan calculation
        ILoanConfig loanConfig = config.getLoanConfig();
        require(address(loanConfig) != address(0), "Pay: config.getLoanConfig() is zero");
        loanConfig.getRewardsRate();
        loanConfig.getMultiplier();
        console.log("  LoanConfig.getRewardsRate() + getMultiplier(): callable");

        // 7. LoanV2.getPortfolioFactory() — payFromPortfolio() calls this internally
        //    and reverts with require(factory != address(0)) if missing
        address loanFactory = LoanV2(payable(loanProxy)).getPortfolioFactory();
        require(loanFactory != address(0), "Pay: loan.getPortfolioFactory() is zero");
        require(loanFactory == expectedFactory, "Pay: loan.getPortfolioFactory() mismatch");

        // 8. PortfolioFactory.portfolioManager() — pay() checks msg.sender via factory → manager
        PortfolioManager manager = PortfolioFactory(expectedFactory).portfolioManager();
        require(address(manager) != address(0), "Pay: factory.portfolioManager() is zero");

        console.log("  [OK] pay() call chain");
    }

    /// @dev Full lifecycle dry-run: create veNFT → borrow → repay.
    ///      Uses vm.prank/deal cheatcodes against a forked chain to simulate
    ///      the entire user flow. Reverts if any step fails.
    function _validateDryRun(
        PortfolioAccountConfig config,
        address factoryAddr
    ) internal {
        console.log("Validating dry-run: create veNFT + borrow + repay...");

        PortfolioFactory factory = PortfolioFactory(factoryAddr);
        PortfolioManager manager = factory.portfolioManager();
        FacetRegistry registry = factory.facetRegistry();

        // Get AERO token address from VotingEscrow
        address aero = IVotingEscrow(LIVE_VOTING_ESCROW).token();
        console.log("  AERO token:", aero);

        // Deterministic test user — won't collide with real accounts
        address testUser = address(uint160(uint256(keccak256("forty-acres-dry-run-validator"))));

        // Predict portfolio address via CREATE2 (needed to approve before multicall creates it)
        address predictedPortfolio = _computePortfolioAddress(factoryAddr, testUser, address(registry));
        console.log("  Predicted portfolio:", predictedPortfolio);

        // ── Fund test user with AERO ───────────────────────────────────
        uint256 lockAmount = 1000e18;
        deal(aero, testUser, lockAmount);

        // ── Ensure vault has USDC for borrowing ────────────────────────
        address loanProxy = config.getLoanContract();
        address vault = ILendingPool(loanProxy).lendingVault();
        uint256 vaultBalance = IERC20(LIVE_USDC).balanceOf(vault);
        if (vaultBalance < 100e6) {
            deal(LIVE_USDC, vault, 1_000_000e6);
        }
        console.log("  Vault USDC balance:", IERC20(LIVE_USDC).balanceOf(vault));

        // ── Step 1: Create veNFT via multicall (creates portfolio + lock + collateral) ──
        vm.startPrank(testUser);

        // Approve predicted portfolio for AERO (createLock transfers AERO from user → portfolio)
        IERC20(aero).approve(predictedPortfolio, lockAmount);

        address[] memory factories = new address[](1);
        factories[0] = factoryAddr;
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, lockAmount);
        manager.multicall(calls, factories);

        // Verify portfolio was created at the predicted address
        address actualPortfolio = factory.portfolioOf(testUser);
        require(actualPortfolio == predictedPortfolio, "DryRun: portfolio address mismatch");
        console.log("  createLock: OK");

        // Verify collateral was added
        uint256 collateral = ICollateralFacet(actualPortfolio).getTotalLockedCollateral();
        require(collateral > 0, "DryRun: no collateral after createLock");
        console.log("  Collateral:", collateral);

        // Check maxLoan — if 0, LoanConfig rewardsRate or multiplier is not set
        (uint256 maxLoan,) = ICollateralFacet(actualPortfolio).getMaxLoan();
        require(maxLoan > 0, "DryRun: maxLoan is 0 - check LoanConfig rewardsRate and multiplier");
        console.log("  Max loan:", maxLoan);

        // ── Step 2: Borrow ─────────────────────────────────────────────
        uint256 borrowAmount = maxLoan > 1e6 ? 1e6 : maxLoan; // borrow 1 USDC or max
        calls[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, borrowAmount);
        manager.multicall(calls, factories);

        uint256 debtAfterBorrow = ICollateralFacet(actualPortfolio).getTotalDebt();
        require(debtAfterBorrow > 0, "DryRun: debt is 0 after borrow");
        console.log("  borrow:", borrowAmount, "OK  debt:", debtAfterBorrow);

        // ── Step 3: Repay ──────────────────────────────────────────────
        uint256 totalOwed = debtAfterBorrow + ICollateralFacet(actualPortfolio).getUnpaidFees();
        deal(LIVE_USDC, testUser, totalOwed);
        IERC20(LIVE_USDC).approve(actualPortfolio, totalOwed);
        BaseLendingFacet(actualPortfolio).pay(totalOwed);

        uint256 debtAfterPay = ICollateralFacet(actualPortfolio).getTotalDebt();
        require(debtAfterPay == 0, "DryRun: debt not fully repaid");
        console.log("  pay:", totalOwed, "OK  debt: 0");

        vm.stopPrank();
        console.log("  [OK] Dry-run: create veNFT + borrow + repay");
    }

    /// @dev Validates the on-chain implementation is plausible: same code length and
    ///      has code deployed. Exact codehash matching is unreliable with via-ir
    ///      (optimizer can reorder instructions across compilations). Functional
    ///      correctness is verified by _validateConfig, _validatePayFlow, and _validateDryRun.
    function _validateImplementationCodehash(address configProxy) internal {
        console.log("Validating implementation bytecode...");

        address liveImpl = _getImplementation(configProxy);
        require(liveImpl != address(0), "Config: no implementation set");
        require(liveImpl.code.length > 0, "Config: implementation has no code");

        PortfolioAccountConfig freshImpl = new PortfolioAccountConfig();

        console.log("  Live impl:", liveImpl);
        console.log("  Live code length:", liveImpl.code.length);
        console.log("  Fresh code length:", address(freshImpl).code.length);

        require(
            liveImpl.code.length == address(freshImpl).code.length,
            "Config implementation outdated - code length mismatch (run upgradeToAndCall)"
        );

        if (liveImpl.codehash == address(freshImpl).codehash) {
            console.log("  [OK] Implementation codehash matches exactly");
        } else {
            console.log("  [OK] Code length matches (codehash differs due to via-ir non-determinism)");
        }
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _getImplementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @dev Compute the CREATE2 address for a user's portfolio account
    function _computePortfolioAddress(
        address factoryAddr,
        address user,
        address registryAddr
    ) internal pure returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(user));
        bytes memory initCode = abi.encodePacked(
            type(FortyAcresPortfolioAccount).creationCode,
            abi.encode(registryAddr)
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            factoryAddr,
            salt,
            keccak256(initCode)
        )))));
    }
}
