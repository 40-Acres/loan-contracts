// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

import {HydrexPortfolioFactoryConfig} from "../../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";

import {VeHydrexVotingEscrowFacet} from "../../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {VeHydrexFacet} from "../../../../src/facets/account/veHydrex/VeHydrexFacet.sol";
import {VeHydrexClaimingFacet} from "../../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";

import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {HydrexCollateralManager} from "../../../../src/facets/account/veHydrex/HydrexCollateralManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockHydrexVotingEscrow} from "../mocks/MockHydrexVotingEscrow.sol";
import {MockHydrexVoter} from "../mocks/MockHydrexVoter.sol";
import {MockHydrexRewardsDistributor} from "../mocks/MockHydrexRewardsDistributor.sol";
import {MockLendingPool, MockVaultShell} from "../mocks/MockLendingPool.sol";

/// @notice Thin facet exposing HydrexCollateralManager and HydrexPortfolioFactoryConfig
///         views/methods through delegatecall on the portfolio account.
///         Provides borrow + pay surfaces backed by HydrexCollateralManager for
///         the dynamic-collateral-manager tests.
contract HydrexCollateralFacet is ICollateralFacet {
    PortfolioFactory public immutable _portfolioFactory;
    address public immutable _votingEscrow;

    constructor(address portfolioFactory, address ve) {
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = ve;
    }

    function getTotalLockedCollateral() external view returns (uint256) {
        return HydrexCollateralManager.getTotalLockedCollateral();
    }

    function getTotalDebt() external view returns (uint256) {
        return HydrexCollateralManager.getTotalDebt();
    }

    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return HydrexCollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function enforceCollateralRequirements() external view returns (bool) {
        return HydrexCollateralManager.enforceCollateralRequirements();
    }

    function getLoanUtilization() external view returns (uint256) {
        return HydrexCollateralManager.getLoanUtilization(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function getCollateralToken() external view returns (address) {
        return _votingEscrow;
    }

    function getLockedCollateral(uint256 tokenId) external view returns (uint256) {
        return HydrexCollateralManager.getLockedCollateral(tokenId);
    }

    function getOriginTimestamp(uint256 tokenId) external view returns (uint256) {
        return HydrexCollateralManager.getOriginTimestamp(tokenId);
    }

    function increaseTotalDebt(uint256 amount) external returns (uint256, uint256) {
        return HydrexCollateralManager.increaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), amount);
    }

    function decreaseTotalDebt(uint256 amount) external returns (uint256) {
        return HydrexCollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), amount);
    }

    function getRebaseBucket() external view returns (uint256) {
        return HydrexPortfolioFactoryConfig(address(_portfolioFactory.portfolioFactoryConfig()))
            .getRebaseTokenId(address(this));
    }
}

/// @notice Bootstraps a diamond that exposes the three Hydrex facets and the
///         test-only collateral-view facet. Returns a portfolio account address
///         that callers can poke via delegatecall paths.
abstract contract VeHydrexDiamond is Test {
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal user = address(0x40Ac2E);
    address internal authorizedCaller = address(0xaaaaa);

    PortfolioManager internal portfolioManager;
    PortfolioFactory internal portfolioFactory;
    FacetRegistry internal facetRegistry;
    HydrexPortfolioFactoryConfig internal portfolioFactoryConfig;
    VotingConfig internal votingConfig;
    LoanConfig internal loanConfig;

    MockERC20 internal underlying; // HYDX
    MockERC20 internal usdc;        // lending asset
    MockHydrexVotingEscrow internal ve;
    MockHydrexVoter internal voter;
    MockHydrexRewardsDistributor internal rewardsDistributor;
    MockLendingPool internal lendingPool;
    MockVaultShell internal vault;

    VeHydrexVotingEscrowFacet internal vfFacet;
    VeHydrexFacet internal vhFacet;
    VeHydrexClaimingFacet internal claimFacet;
    HydrexCollateralFacet internal collFacet;

    address internal portfolioAccount;

    uint256 internal constant MIN_COLLATERAL = 1e18;
    uint256 internal constant REWARDS_RATE_PPM = 285_0; // 2850
    uint256 internal constant MULTIPLIER = 52;

    function _bootstrap() internal {
        underlying = new MockERC20("HYDX", "HYDX", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        ve = new MockHydrexVotingEscrow(address(underlying));
        voter = new MockHydrexVoter();
        rewardsDistributor = new MockHydrexRewardsDistributor(address(ve));

        vm.startPrank(owner_);
        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("vehydrex-harness", block.timestamp))
        );
        portfolioFactory = pf;
        facetRegistry = fr;

        // Hydrex config
        HydrexPortfolioFactoryConfig configImpl = new HydrexPortfolioFactoryConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), "");
        portfolioFactoryConfig = HydrexPortfolioFactoryConfig(address(configProxy));
        portfolioFactoryConfig.initialize(owner_, address(portfolioFactory));

        // VotingConfig
        VotingConfig vcImpl = new VotingConfig();
        ERC1967Proxy vcProxy = new ERC1967Proxy(address(vcImpl), "");
        votingConfig = VotingConfig(address(vcProxy));
        votingConfig.initialize(owner_);

        // LoanConfig
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

        // LendingPool + vault shell. We bind the loan contract before facet
        // creation so all selectors resolve consistently.
        vault = new MockVaultShell(address(usdc));
        lendingPool = new MockLendingPool(address(usdc), address(vault), address(portfolioFactory));
        portfolioFactoryConfig.setLoanContract(address(lendingPool));
        // Seed vault with USDC so getMaxLoan can return non-zero supply.
        usdc.mint(address(vault), 10_000_000e6);

        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Register facets
        _registerFacets();

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);
    }

    function _registerFacets() internal {
        // VeHydrexVotingEscrowFacet
        vfFacet = new VeHydrexVotingEscrowFacet(address(portfolioFactory), address(ve));
        {
            bytes4[] memory s = new bytes4[](6);
            s[0] = VeHydrexVotingEscrowFacet.createLock.selector;
            s[1] = VeHydrexVotingEscrowFacet.increaseLock.selector;
            s[2] = VeHydrexVotingEscrowFacet.merge.selector;
            s[3] = VeHydrexVotingEscrowFacet.mergeInternal.selector;
            s[4] = VeHydrexVotingEscrowFacet.split.selector;
            s[5] = VeHydrexVotingEscrowFacet.onERC721Received.selector;
            facetRegistry.registerFacet(address(vfFacet), s, "VeHydrexVotingEscrowFacet");
        }

        // VeHydrexFacet
        vhFacet = new VeHydrexFacet(address(portfolioFactory), address(votingConfig), address(ve), address(voter));
        {
            bytes4[] memory s = new bytes4[](6);
            s[0] = VeHydrexFacet.vote.selector;
            s[1] = VeHydrexFacet.batchVote.selector;
            s[2] = VeHydrexFacet.defaultVote.selector;
            s[3] = VeHydrexFacet.isManualVoting.selector;
            s[4] = VeHydrexFacet.setVotingMode.selector;
            s[5] = VeHydrexFacet.isElligibleForManualVoting.selector;
            facetRegistry.registerFacet(address(vhFacet), s, "VeHydrexFacet");
        }

        // VeHydrexClaimingFacet
        claimFacet = new VeHydrexClaimingFacet(
            address(portfolioFactory), address(ve), address(voter), address(rewardsDistributor)
        );
        {
            bytes4[] memory s = new bytes4[](2);
            s[0] = ClaimingFacet.claimFees.selector;
            s[1] = ClaimingFacet.claimRebase.selector;
            facetRegistry.registerFacet(address(claimFacet), s, "VeHydrexClaimingFacet");
        }

        // Collateral view + borrow / pay
        collFacet = new HydrexCollateralFacet(address(portfolioFactory), address(ve));
        {
            bytes4[] memory s = new bytes4[](11);
            s[0] = ICollateralFacet.getTotalLockedCollateral.selector;
            s[1] = ICollateralFacet.getTotalDebt.selector;
            s[2] = ICollateralFacet.getMaxLoan.selector;
            s[3] = ICollateralFacet.enforceCollateralRequirements.selector;
            s[4] = ICollateralFacet.getLoanUtilization.selector;
            s[5] = ICollateralFacet.getCollateralToken.selector;
            s[6] = HydrexCollateralFacet.getLockedCollateral.selector;
            s[7] = HydrexCollateralFacet.getOriginTimestamp.selector;
            s[8] = HydrexCollateralFacet.increaseTotalDebt.selector;
            s[9] = HydrexCollateralFacet.decreaseTotalDebt.selector;
            s[10] = HydrexCollateralFacet.getRebaseBucket.selector;
            facetRegistry.registerFacet(address(collFacet), s, "HydrexCollateralFacet");
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
