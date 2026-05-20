// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

import {HydrexPortfolioFactoryConfig} from "../../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";

import {DynamicVeHydrexVotingEscrowFacet} from "../../../../src/facets/account/veHydrex/DynamicVeHydrexVotingEscrowFacet.sol";
import {DynamicVeHydrexFacet} from "../../../../src/facets/account/veHydrex/DynamicVeHydrexFacet.sol";
import {DynamicVeHydrexClaimingFacet} from "../../../../src/facets/account/veHydrex/DynamicVeHydrexClaimingFacet.sol";
import {DynamicHydrexLendingFacet} from "../../../../src/facets/account/veHydrex/DynamicHydrexLendingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {VeHydrexFacet} from "../../../../src/facets/account/veHydrex/VeHydrexFacet.sol";
import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";

import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {DynamicHydrexCollateralManager} from "../../../../src/facets/account/veHydrex/DynamicHydrexCollateralManager.sol";

import {DynamicFeesVault} from "../../../../src/facets/account/vault/DynamicFeesVault.sol";
import {KinkFeeCalculator} from "../../../../src/facets/account/vault/KinkFeeCalculator.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockHydrexVotingEscrow} from "../mocks/MockHydrexVotingEscrow.sol";
import {MockHydrexVoter} from "../mocks/MockHydrexVoter.sol";
import {MockHydrexRewardsDistributor} from "../mocks/MockHydrexRewardsDistributor.sol";

/// @notice Thin view facet exposing DynamicHydrexCollateralManager state via
///         delegatecall. Mirrors HydrexCollateralFacet from VeHydrexDiamond.sol
///         but routes reads/writes to the DynamicHydrexCollateralManager
///         storage slot. Borrow/pay routing lives on DynamicHydrexLendingFacet.
contract DynamicHydrexCollateralViewFacet is ICollateralFacet {
    PortfolioFactory public immutable _portfolioFactory;
    address public immutable _votingEscrow;

    constructor(address portfolioFactory, address ve) {
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = ve;
    }

    function getTotalLockedCollateral() external view returns (uint256) {
        return DynamicHydrexCollateralManager.getTotalLockedCollateral();
    }

    function getTotalDebt() external view returns (uint256) {
        return DynamicHydrexCollateralManager.getTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return DynamicHydrexCollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function enforceCollateralRequirements() external view returns (bool) {
        return DynamicHydrexCollateralManager.enforceCollateralRequirements();
    }

    function getLoanUtilization() external view returns (uint256) {
        return DynamicHydrexCollateralManager.getLoanUtilization(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function getCollateralToken() external view returns (address) {
        return _votingEscrow;
    }

    function getLockedCollateral(uint256 tokenId) external view returns (uint256) {
        return DynamicHydrexCollateralManager.getLockedCollateral(tokenId);
    }

    function getOriginTimestamp(uint256 tokenId) external view returns (uint256) {
        return DynamicHydrexCollateralManager.getOriginTimestamp(tokenId);
    }
}

/// @notice Diamond bootstrapper for the Dynamic-variant veHydrex facets.
///         Wires the six Dynamic* facets against a real DynamicFeesVault
///         (deployed via ERC1967 proxy + KinkFeeCalculator). The vault doubles
///         as the loan contract (ILendingPool) since DynamicFeesVault's
///         lendingVault() returns address(this).
///
///         Storage slot under exercise: storage.DynamicHydrexCollateralManager
///         (distinct from the simple HydrexCollateralManager slot used by
///         VeHydrexDiamond). The two diamonds can coexist in the same test
///         binary without slot collisions.
abstract contract DynamicVeHydrexDiamond is Test {
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal user = address(0x40Ac2E);
    address internal authorizedCaller = address(0xaaaaa);
    address internal feeRecipient = address(0xFEEEEE);

    PortfolioManager internal portfolioManager;
    PortfolioFactory internal portfolioFactory;
    FacetRegistry internal facetRegistry;
    HydrexPortfolioFactoryConfig internal portfolioFactoryConfig;
    VotingConfig internal votingConfig;
    LoanConfig internal loanConfig;

    MockERC20 internal underlying; // HYDX
    MockERC20 internal usdc;        // lending asset (DynamicFeesVault.asset())
    MockHydrexVotingEscrow internal ve;
    MockHydrexVoter internal voter;
    MockHydrexRewardsDistributor internal rewardsDistributor;
    DynamicFeesVault internal vault;
    KinkFeeCalculator internal feeCalculator;

    DynamicVeHydrexVotingEscrowFacet internal vfFacet;
    DynamicVeHydrexFacet internal vhFacet;
    DynamicVeHydrexClaimingFacet internal claimFacet;
    DynamicHydrexLendingFacet internal lendingFacet;
    DynamicHydrexCollateralViewFacet internal collFacet;

    address internal portfolioAccount;

    uint256 internal constant MIN_COLLATERAL = 1e18;
    uint256 internal constant REWARDS_RATE_PPM = 285_0; // 2850
    uint256 internal constant MULTIPLIER = 52;
    uint256 internal constant VAULT_USDC_LIQ = 10_000_000e6;

    function _bootstrap() internal {
        underlying = new MockERC20("HYDX", "HYDX", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        ve = new MockHydrexVotingEscrow(address(underlying));
        voter = new MockHydrexVoter();
        rewardsDistributor = new MockHydrexRewardsDistributor(address(ve));

        vm.startPrank(owner_);
        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("dyn-vehydrex-harness", block.timestamp))
        );
        portfolioFactory = pf;
        facetRegistry = fr;

        // Hydrex config (same impl used by both simple and dynamic paths).
        HydrexPortfolioFactoryConfig configImpl = new HydrexPortfolioFactoryConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), "");
        portfolioFactoryConfig = HydrexPortfolioFactoryConfig(address(configProxy));
        portfolioFactoryConfig.initialize(owner_, address(portfolioFactory));

        // VotingConfig
        VotingConfig vcImpl = new VotingConfig();
        ERC1967Proxy vcProxy = new ERC1967Proxy(address(vcImpl), "");
        votingConfig = VotingConfig(address(vcProxy));
        votingConfig.initialize(owner_);

        // LoanConfig - same shape as the simple harness so the maxLoan math
        // produces equivalent numbers.
        LoanConfig lcImpl = new LoanConfig();
        ERC1967Proxy lcProxy = new ERC1967Proxy(address(lcImpl), "");
        loanConfig = LoanConfig(address(lcProxy));
        loanConfig.initialize(owner_, 20_00, 5_00, 1_00);
        loanConfig.setRewardsRate(REWARDS_RATE_PPM);
        loanConfig.setMultiplier(MULTIPLIER);
        loanConfig.setMaxUtilizationBps(8000);

        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));
        portfolioFactoryConfig.setMinimumCollateral(MIN_COLLATERAL);

        // DynamicFeesVault: real ERC4626 vault that doubles as the loan
        // contract. lendingVault() returns address(this).
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(
                DynamicFeesVault.initialize,
                (address(usdc), "dyn-vault", "dv", address(portfolioFactory), feeRecipient, 0)
            )
        );
        vault = DynamicFeesVault(address(vaultProxy));

        // Swap in KinkFeeCalculator for predictable fee curve in tests.
        feeCalculator = new KinkFeeCalculator();
        vault.setFeeCalculator(address(feeCalculator));

        portfolioFactoryConfig.setLoanContract(address(vault));
        // Seed vault with USDC so getMaxLoan returns non-zero supply.
        usdc.mint(address(vault), VAULT_USDC_LIQ);

        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        _registerFacets();

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);
    }

    function _registerFacets() internal {
        // DynamicVeHydrexVotingEscrowFacet
        vfFacet = new DynamicVeHydrexVotingEscrowFacet(address(portfolioFactory), address(ve));
        {
            bytes4[] memory s = new bytes4[](6);
            s[0] = VeHydrexVotingEscrowFacet.createLock.selector;
            s[1] = VeHydrexVotingEscrowFacet.increaseLock.selector;
            s[2] = VeHydrexVotingEscrowFacet.merge.selector;
            s[3] = VeHydrexVotingEscrowFacet.mergeInternal.selector;
            s[4] = VeHydrexVotingEscrowFacet.split.selector;
            s[5] = VeHydrexVotingEscrowFacet.onERC721Received.selector;
            facetRegistry.registerFacet(address(vfFacet), s, "DynamicVeHydrexVotingEscrowFacet");
        }

        // DynamicVeHydrexFacet
        vhFacet = new DynamicVeHydrexFacet(
            address(portfolioFactory), address(votingConfig), address(ve), address(voter)
        );
        {
            bytes4[] memory s = new bytes4[](6);
            s[0] = VeHydrexFacet.vote.selector;
            s[1] = VeHydrexFacet.batchVote.selector;
            s[2] = VeHydrexFacet.defaultVote.selector;
            s[3] = VeHydrexFacet.isManualVoting.selector;
            s[4] = VeHydrexFacet.setVotingMode.selector;
            s[5] = VeHydrexFacet.isElligibleForManualVoting.selector;
            facetRegistry.registerFacet(address(vhFacet), s, "DynamicVeHydrexFacet");
        }

        // DynamicVeHydrexClaimingFacet
        claimFacet = new DynamicVeHydrexClaimingFacet(
            address(portfolioFactory), address(ve), address(voter), address(rewardsDistributor)
        );
        {
            bytes4[] memory s = new bytes4[](2);
            s[0] = ClaimingFacet.claimFees.selector;
            s[1] = ClaimingFacet.claimRebase.selector;
            facetRegistry.registerFacet(address(claimFacet), s, "DynamicVeHydrexClaimingFacet");
        }

        // DynamicHydrexLendingFacet - borrow / pay routed through
        // DynamicHydrexCollateralManager onto the DynamicFeesVault.
        lendingFacet = new DynamicHydrexLendingFacet(address(portfolioFactory), address(usdc));
        {
            bytes4[] memory s = new bytes4[](4);
            s[0] = BaseLendingFacet.borrow.selector;
            s[1] = BaseLendingFacet.pay.selector;
            s[2] = BaseLendingFacet.setTopUp.selector;
            s[3] = BaseLendingFacet.topUp.selector;
            facetRegistry.registerFacet(address(lendingFacet), s, "DynamicHydrexLendingFacet");
        }

        // Collateral views routed against the Dynamic storage slot. The
        // bucket-pointer read is served by HydrexPortfolioFactoryConfig directly
        // in tests, so no per-facet shim is needed (parity with simple helper
        // minus that one selector).
        collFacet = new DynamicHydrexCollateralViewFacet(address(portfolioFactory), address(ve));
        {
            bytes4[] memory s = new bytes4[](8);
            s[0] = ICollateralFacet.getTotalLockedCollateral.selector;
            s[1] = ICollateralFacet.getTotalDebt.selector;
            s[2] = ICollateralFacet.getMaxLoan.selector;
            s[3] = ICollateralFacet.enforceCollateralRequirements.selector;
            s[4] = ICollateralFacet.getLoanUtilization.selector;
            s[5] = ICollateralFacet.getCollateralToken.selector;
            s[6] = DynamicHydrexCollateralViewFacet.getLockedCollateral.selector;
            s[7] = DynamicHydrexCollateralViewFacet.getOriginTimestamp.selector;
            facetRegistry.registerFacet(address(collFacet), s, "DynamicHydrexCollateralViewFacet");
        }
    }

    /// @notice Build the multicall calldata vector used in tests.
    function _mc(bytes memory data) internal view returns (bytes[] memory cd, address[] memory fac) {
        cd = new bytes[](1);
        cd[0] = data;
        fac = new address[](1);
        fac[0] = address(portfolioFactory);
    }
}
