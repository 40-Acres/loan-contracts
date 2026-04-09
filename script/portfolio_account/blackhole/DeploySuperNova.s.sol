// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";

import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../src/facets/account/votingEscrow/BlackholeVotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {BlackholeRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/BlackholeRewardsProcessingFacet.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

contract SuperNovaRootDeploy is PortfolioFactoryConfigDeploy {
    // SuperNova / Ethereum Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Ethereum USDC
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44; // veNOVA
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171; // SuperNova VoterV3
    address public constant REWARDS_DISTRIBUTOR = 0xB3410A30af5033aF822B8eA5Ad3bd0a19490ea97; // SuperNova RewardsDistributor
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78; // NOVA token

    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        _portfolioManager = new PortfolioManager{salt: SALT}(DEPLOYER_ADDRESS);
        require(address(_portfolioManager) == address(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9), "Unexpected PortfolioManager address");
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("supernova-usdc"))));

        // Deploy config contracts
        (PortfolioFactoryConfig portfolioFactoryConfig, VotingConfig votingConfig, LoanConfig loanConfig) = PortfolioFactoryConfigDeploy._deploy(false, address(portfolioFactory));
        SwapConfig swapConfig = _deploySwapConfig(DEPLOYER_ADDRESS);

        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        _portfolioFactory = portfolioFactory;

        // Deploy fresh Loan contract
        Loan loanImplementation = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImplementation), "");
        _loanContract = address(loanProxy);

        // Create vault
        Vault vaultImplementation = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        Vault vault = Vault(address(vaultProxy));

        // Initialize vault
        vault.initialize(address(USDC), address(_loanContract), "40eth-USDC-VAULT", "40eth-USDC-VAULT");

        // Initialize loan
        Loan(address(_loanContract)).initialize(address(vault), USDC);
        LoanV2 loanV2 = new LoanV2();
        LoanV2(address(_loanContract)).upgradeToAndCall(address(loanV2), new bytes(0));
        Loan(address(_loanContract)).setPortfolioFactory(address(portfolioFactory));

        portfolioFactoryConfig.setLoanContract(address(_loanContract));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Deploy ClaimingFacet (single rewards distributor for SuperNova)
        ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        bytes4[] memory claimingSelectors = new bytes4[](3);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // Deploy CollateralFacet
        CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory collateralSelectors = new bytes4[](10);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSelectors[8] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSelectors[9] = BaseCollateralFacet.removeCollateralTo.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Deploy LendingFacet
        LendingFacet lendingFacet = new LendingFacet(address(portfolioFactory), USDC);
        bytes4[] memory lendingSelectors = new bytes4[](5);
        lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        lendingSelectors[1] = BaseLendingFacet.pay.selector;
        lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        lendingSelectors[3] = BaseLendingFacet.topUp.selector;
        lendingSelectors[4] = BaseLendingFacet.borrowTo.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "LendingFacet");

        // Deploy VotingFacet
        VotingFacet votingFacet = new VotingFacet(address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = VotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy BlackholeVotingEscrowFacet (shared with Blackhole — handles increase_amount/create_lock_for)
        BlackholeVotingEscrowFacet votingEscrowFacet = new BlackholeVotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](5);
        votingEscrowSelectors[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = BlackholeVotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = BlackholeVotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        votingEscrowSelectors[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // Deploy MigrationFacet
        MigrationFacet migrationFacet = new MigrationFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory migrationSelectors = new bytes4[](1);
        migrationSelectors[0] = IMigrationFacet.migrate.selector;
        _registerFacet(facetRegistry, address(migrationFacet), migrationSelectors, "MigrationFacet");

        // Deploy BlackholeRewardsProcessingFacet (shared — handles increase_amount for lock increase)
        RewardsProcessingFacet rewardsProcessingFacet = new BlackholeRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(vault), SNOVA_TOKEN);
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

        // Deploy RewardsConfigFacet
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(address(portfolioFactory));
        bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");
    }

}

// forge script script/portfolio_account/blackhole/DeploySuperNova.s.sol:SuperNovaRootDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
