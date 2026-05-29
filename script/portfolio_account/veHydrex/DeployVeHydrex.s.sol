// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {console} from "forge-std/console.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {VeHydrexFacet} from "../../../src/facets/account/veHydrex/VeHydrexFacet.sol";
import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {DynamicVeHydrexFacet} from "../../../src/facets/account/veHydrex/DynamicVeHydrexFacet.sol";
import {DynamicVeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/DynamicVeHydrexClaimingFacet.sol";
import {DynamicVeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/DynamicVeHydrexVotingEscrowFacet.sol";
import {DynamicHydrexCollateralFacet} from "../../../src/facets/account/veHydrex/DynamicHydrexCollateralFacet.sol";
import {DynamicHydrexLendingFacet} from "../../../src/facets/account/veHydrex/DynamicHydrexLendingFacet.sol";
import {DynamicHydrexRewardsProcessingFacet} from "../../../src/facets/account/veHydrex/DynamicHydrexRewardsProcessingFacet.sol";

import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";

import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";

/**
 * @dev Deploys a Hydrex-on-DynamicFees portfolio diamond on Base.
 *      Hydrex's RewardsDistributor auto-locks rebase emissions; rebase-bucket
 *      handling for non-PERMANENT originals lives in VeHydrexVotingEscrowFacet's
 *      receiver hook, backed by a per-account slot on HydrexPortfolioFactoryConfig.
 */
contract VeHydrexDynamicFeesDeploy is PortfolioFactoryConfigDeploy {
    // PortfolioFactory + FacetRegistry already deployed by the multisig
    // (via portfolioManager9 keccak256("hydrex-usdc-dynamic").
    // address public constant PORTFOLIO_FACTORY = 0x0;
    address public constant FACET_REGISTRY = 0x60Ab719aa7e0De6797e1619FCeACaB29C2A9E24b;

    // Base chain external addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant HYDREX_VOTING_ESCROW = 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1;
    address public constant HYDREX_VOTER = 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b;
    address public constant HYDREX_REWARDS_DISTRIBUTOR = 0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42;

    PortfolioFactory public _portfolioFactory;
    DynamicFeesVault public _vault;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        SwapConfig swapConfig = SwapConfig(BASE_SWAP_CONFIG);

        PortfolioFactory portfolioFactory = PortfolioFactory(0x0000000000000000000000000000000000000000);
        FacetRegistry facetRegistry = FacetRegistry(FACET_REGISTRY);
        require(address(portfolioFactory.facetRegistry()) == FACET_REGISTRY, "FacetRegistry mismatch");
        _portfolioFactory = portfolioFactory;

        // HydrexPortfolioFactoryConfig holds the rebase-bucket slot per account.
        HydrexPortfolioFactoryConfig configImpl = new HydrexPortfolioFactoryConfig();
        bytes memory configInitData =
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER_ADDRESS, address(portfolioFactory)));
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), configInitData);
        HydrexPortfolioFactoryConfig portfolioFactoryConfig = HydrexPortfolioFactoryConfig(address(configProxy));

        VotingConfig votingConfigImpl = new VotingConfig();
        bytes memory votingConfigInitData = abi.encodeCall(VotingConfig.initialize, (DEPLOYER_ADDRESS));
        ERC1967Proxy votingConfigProxy = new ERC1967Proxy(address(votingConfigImpl), votingConfigInitData);
        VotingConfig votingConfig = VotingConfig(address(votingConfigProxy));

        LoanConfig loanConfigImpl = new LoanConfig();
        bytes memory loanConfigInitData = abi.encodeCall(LoanConfig.initialize, (DEPLOYER_ADDRESS, 20_00, 5_00, 1_00));
        ERC1967Proxy loanConfigProxy = new ERC1967Proxy(address(loanConfigImpl), loanConfigInitData);
        LoanConfig loanConfig = LoanConfig(address(loanConfigProxy));

        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory vaultInitData = abi.encodeCall(
            DynamicFeesVault.initialize,
            (USDC, "40ACRES-HYDREX-USDC-VAULT", "40ACRES-HYDREX-USDC", address(portfolioFactory), MULTISIG_ADDRESS, 0)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        _vault = DynamicFeesVault(address(vaultProxy));
        _vault.setOriginationFeeBps(80);

        portfolioFactoryConfig.setLoanContract(address(_vault));
        // portfolioFactory.setPortfolioFactoryConfig(...) is multisig-gated (PortfolioManager.owner).
        // The multisig must call it post-deploy with the address logged below.

        // VeHydrexClaimingFacet
        DynamicVeHydrexClaimingFacet claimingFacet = new DynamicVeHydrexClaimingFacet(
            address(portfolioFactory), HYDREX_VOTING_ESCROW, HYDREX_VOTER, HYDREX_REWARDS_DISTRIBUTOR
        );
        bytes4[] memory claimingSelectors = new bytes4[](2);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "DynamicVeHydrexClaimingFacet");

        // DynamicHydrexCollateralFacet (collateral view + admin surface)
        DynamicHydrexCollateralFacet collateralFacet =
            new DynamicHydrexCollateralFacet(address(portfolioFactory), HYDREX_VOTING_ESCROW);
        bytes4[] memory collateralSelectors = new bytes4[](11);
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
        collateralSelectors[10] = BaseCollateralFacet.getLoanUtilization.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "DynamicHydrexCollateralFacet");

        // DynamicHydrexLendingFacet
        DynamicHydrexLendingFacet lendingFacet = new DynamicHydrexLendingFacet(address(portfolioFactory), USDC);
        bytes4[] memory lendingSelectors = new bytes4[](5);
        lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        lendingSelectors[1] = BaseLendingFacet.pay.selector;
        lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        lendingSelectors[3] = BaseLendingFacet.topUp.selector;
        lendingSelectors[4] = BaseLendingFacet.borrowTo.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "DynamicHydrexLendingFacet");

        // VeHydrexFacet
        DynamicVeHydrexFacet votingFacet = new DynamicVeHydrexFacet(
            address(portfolioFactory), address(votingConfig), HYDREX_VOTING_ESCROW, HYDREX_VOTER
        );
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = VeHydrexFacet.vote.selector;
        votingSelectors[1] = VeHydrexFacet.batchVote.selector;
        votingSelectors[2] = VeHydrexFacet.setVotingMode.selector;
        votingSelectors[3] = VeHydrexFacet.isManualVoting.selector;
        votingSelectors[4] = VeHydrexFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "DynamicVeHydrexFacet");

        // VeHydrexVotingEscrowFacet
        DynamicVeHydrexVotingEscrowFacet votingEscrowFacet =
            new DynamicVeHydrexVotingEscrowFacet(address(portfolioFactory), HYDREX_VOTING_ESCROW);
        bytes4[] memory votingEscrowSelectors = new bytes4[](6);
        votingEscrowSelectors[0] = VeHydrexVotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = VeHydrexVotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = VeHydrexVotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = VeHydrexVotingEscrowFacet.mergeInternal.selector;
        votingEscrowSelectors[4] = VeHydrexVotingEscrowFacet.split.selector;
        votingEscrowSelectors[5] = VeHydrexVotingEscrowFacet.onERC721Received.selector;
        _registerFacet(
            facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "DynamicVeHydrexVotingEscrowFacet"
        );

        // DynamicHydrexRewardsProcessingFacet
        DynamicHydrexRewardsProcessingFacet rewardsProcessingFacet = new DynamicHydrexRewardsProcessingFacet(
            address(portfolioFactory),
            address(swapConfig),
            HYDREX_VOTING_ESCROW,
            address(_vault),
            IHydrexVotingEscrow(HYDREX_VOTING_ESCROW).token(),
            USDC
        );
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(
            facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "DynamicHydrexRewardsProcessingFacet"
        );

        // RewardsConfigFacet (protocol-agnostic)
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(address(portfolioFactory), address(swapConfig));
        bytes4[] memory rewardsConfigSelectors = new bytes4[](6);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");

        // Hand over ownership to the multisig. Ownable2Step requires the multisig
        // to call acceptOwnership() on each contract to finalize the transfer.
        portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
        votingConfig.transferOwnership(MULTISIG_ADDRESS);
        loanConfig.transferOwnership(MULTISIG_ADDRESS);
        _vault.transferOwnership(MULTISIG_ADDRESS);

        console.log("=== Deployed addresses ===");
        console.log("PortfolioFactoryConfig:", address(portfolioFactoryConfig));
        console.log("VotingConfig:          ", address(votingConfig));
        console.log("LoanConfig:            ", address(loanConfig));
        console.log("DynamicFeesVault:      ", address(_vault));

        console.log("=== Multisig: setPortfolioFactoryConfig ===");
        // console.log("To:  ", PORTFOLIO_FACTORY);
        console.logBytes(
            abi.encodeWithSelector(PortfolioFactory.setPortfolioFactoryConfig.selector, address(portfolioFactoryConfig))
        );

        console.log("=== Multisig: acceptOwnership (4x) ===");
        console.log("portfolioFactoryConfig:", address(portfolioFactoryConfig));
        console.log("votingConfig:          ", address(votingConfig));
        console.log("loanConfig:            ", address(loanConfig));
        console.log("vault:                 ", address(_vault));
        console.logBytes(abi.encodeWithSignature("acceptOwnership()"));

        _writeDeployJson(address(portfolioFactoryConfig), address(votingConfig), address(loanConfig), address(_vault));
    }

    function _writeDeployJson(address portfolioFactoryConfig_, address votingConfig_, address loanConfig_, address vault_) internal {
        string memory json = "vehydrex-dynamic";
        vm.serializeAddress(json, "portfolioFactory", address(_portfolioFactory));
        vm.serializeAddress(json, "facetRegistry", FACET_REGISTRY);
        vm.serializeAddress(json, "portfolioFactoryConfig", portfolioFactoryConfig_);
        vm.serializeAddress(json, "votingConfig", votingConfig_);
        vm.serializeAddress(json, "loanConfig", loanConfig_);
        string memory finalJson = vm.serializeAddress(json, "dynamicFeesVault", vault_);
        vm.writeJson(finalJson, "./script/portfolio_account/veHydrex/deployed/vehydrex-dynamic.json");
    }
}

// forge script script/portfolio_account/veHydrex/DeployVeHydrex.s.sol:VeHydrexDynamicFeesDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
