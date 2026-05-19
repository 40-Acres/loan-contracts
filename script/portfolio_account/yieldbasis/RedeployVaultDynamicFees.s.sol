// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpLendingFacet.sol";
import {DynamicYieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpClaimingFacet.sol";
import {DynamicYieldBasisLpRewardsProcessingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";

/**
 * @title RedeployVaultDynamicFees
 * @dev Step 1 of the ybETH/WETH supplyVault migration.
 *
 *      Deploys a fresh DynamicFeesVault (WETH underlying) and transfers
 *      ownership to the multisig. Multisig then:
 *        1. acceptOwnership() on the new vault
 *        2. PortfolioFactoryConfig.setLoanContract(newVault)
 *        3. (optional) DynamicFeesVault.setTreasury(<treasury>)
 *
 *      Old vault at 0x204bEE4cFDAa7b318333bCA8f5612c8164F74Ba3 stays deployed
 *      but unused. Existing $100 LP + $100 debt on it are abandoned.
 *
 *      After this script lands and the multisig has repointed the loan
 *      contract, run DynamicYieldBasisLpUpgrade to deploy + register the
 *      four Dynamic LP facets with the new vault address baked in.
 *
 *      Run:
 *        VAULT_UNDERLYING=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
 *        FACTORY_SALT=yieldbasiseth \
 *        forge script script/portfolio_account/yieldbasis/RedeployVaultDynamicFees.s.sol:RedeployVaultDynamicFees \
 *          --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
 */
contract RedeployVaultDynamicFees is PortfolioFactoryConfigDeploy {
    // Lending-asset recipient of accrued fee shares and protocol fees.
    address public constant TREASURY = 0x5FB61F8fC6d8C5767A2B937578A49A1869d0bDa8;

    // Vault metadata. Reusing the legacy LendingVault's name/symbol so on-chain
    // identity tracks the strategy rather than the implementation revision.
    string public constant VAULT_NAME = "40ACRES-ybeth-eth-VAULT";
    string public constant VAULT_SYMBOL = "40ACRES-YBETH-ETH";

    // Performance fee on totalAssets growth. Zero at deploy time; multisig can
    // raise via setFeeBps once liquidity is non-trivial (see SOP: never call
    // setFeeBps on an empty vault).
    uint256 public constant INITIAL_FEE_BPS = 0;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        address underlying = vm.envAddress("VAULT_UNDERLYING");
        require(underlying != address(0), "Set VAULT_UNDERLYING env variable");

        string memory factorySalt = vm.envString("FACTORY_SALT");
        require(bytes(factorySalt).length != 0, "Set FACTORY_SALT env variable");

        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        PortfolioFactory portfolioFactory =
            PortfolioFactory(portfolioManager.factoryBySalt(keccak256(abi.encodePacked(factorySalt))));
        require(address(portfolioFactory) != address(0), "PortfolioFactory not found for salt");

        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory vaultInitData = abi.encodeCall(
            DynamicFeesVault.initialize,
            (underlying, VAULT_NAME, VAULT_SYMBOL, address(portfolioFactory), TREASURY, INITIAL_FEE_BPS)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        DynamicFeesVault vault = DynamicFeesVault(address(vaultProxy));

        // Ownable2Step: multisig must acceptOwnership() to complete the transfer.
        vault.transferOwnership(MULTISIG_ADDRESS);

        console.log("=== DynamicFeesVault deployed ===");
        console.log("Impl :", address(vaultImpl));
        console.log("Proxy:", address(vault));
        console.log("Asset:", underlying);
        console.log("Name :", VAULT_NAME);
        console.log("Symbol:", VAULT_SYMBOL);
        console.log("FeeRecipient:", TREASURY);
        console.log("FeeBps:", INITIAL_FEE_BPS);
        console.log("");
        console.log("Pending multisig actions:");
        console.log("  1. acceptOwnership() on vault proxy");
        console.log("  2. PortfolioFactoryConfig.setLoanContract(", address(vault), ")");
        console.log("  3. (optional) DynamicFeesVault.setTreasury(", TREASURY, ")");
        console.log("");
        console.log("Then run DynamicYieldBasisLpUpgrade with VAULT=", address(vault));
    }
}

/**
 * @title DynamicYieldBasisLpUpgrade
 * @dev Step 2 of the ybETH/WETH supplyVault migration. Deploys the four
 *      Dynamic LP facets pointing at the new vault and registers their
 *      selectors against the FacetRegistry (or prints Safe calldata if the
 *      deployer key does not own the registry).
 *
 *      Run AFTER RedeployVaultDynamicFees has landed and the multisig has
 *      called setLoanContract on the PortfolioFactoryConfig.
 *
 *      Run:
 *        VAULT=<new vault from step 1> \
 *        VAULT_UNDERLYING=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
 *        YIELDBASIS_LP_GAUGE=0xe4e656B5215a82009969219b1bAbB7c0757A3315 \
 *        FACTORY_SALT=yieldbasiseth \
 *        forge script script/portfolio_account/yieldbasis/RedeployVaultDynamicFees.s.sol:DynamicYieldBasisLpUpgrade \
 *          --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
 */
contract DynamicYieldBasisLpUpgrade is PortfolioFactoryConfigDeploy {
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        address gauge = vm.envAddress("YIELDBASIS_LP_GAUGE");
        require(gauge != address(0), "Set YIELDBASIS_LP_GAUGE env variable");

        string memory factorySalt = vm.envString("FACTORY_SALT");
        require(bytes(factorySalt).length != 0, "Set FACTORY_SALT env variable");

        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        PortfolioFactory portfolioFactory =
            PortfolioFactory(portfolioManager.factoryBySalt(keccak256(abi.encodePacked(factorySalt))));

        address vault = vm.envAddress("VAULT");
        require(vault != address(0), "Set VAULT env variable");

        address underlying = vm.envAddress("VAULT_UNDERLYING");
        require(underlying != address(0), "Set VAULT_UNDERLYING env variable");

        FacetRegistry facetRegistry = portfolioFactory.facetRegistry();
        _deployFacets(facetRegistry, address(portfolioFactory), gauge, vault, underlying, ETH_SWAP_CONFIG);

        vm.stopBroadcast();
    }

    function _deployFacets(
        FacetRegistry facetRegistry,
        address portfolioFactory,
        address gauge,
        address vault,
        address underlying,
        address swapConfig
    ) internal {
        // Lp facet: deposit/withdraw + ICollateralFacet surface
        DynamicYieldBasisLpFacet lpFacet = new DynamicYieldBasisLpFacet(portfolioFactory, gauge, YB, vault);
        bytes4[] memory lpSelectors = new bytes4[](10);
        lpSelectors[0] = DynamicYieldBasisLpFacet.deposit.selector;
        lpSelectors[1] = DynamicYieldBasisLpFacet.withdraw.selector;
        lpSelectors[2] = DynamicYieldBasisLpFacet.setStakedMode.selector;
        lpSelectors[3] = DynamicYieldBasisLpFacet.getStakingState.selector;
        lpSelectors[4] = DynamicYieldBasisLpFacet.getTotalLockedCollateral.selector;
        lpSelectors[5] = DynamicYieldBasisLpFacet.getTotalDebt.selector;
        lpSelectors[6] = DynamicYieldBasisLpFacet.getMaxLoan.selector;
        lpSelectors[7] = DynamicYieldBasisLpFacet.enforceCollateralRequirements.selector;
        lpSelectors[8] = DynamicYieldBasisLpFacet.getLoanUtilization.selector;
        lpSelectors[9] = DynamicYieldBasisLpFacet.getCollateralToken.selector;
        _registerFacet(facetRegistry, address(lpFacet), lpSelectors, "DynamicYieldBasisLpFacet");

        // Claiming facet: gauge rewards + LP fee harvesting
        DynamicYieldBasisLpClaimingFacet claimingFacet =
            new DynamicYieldBasisLpClaimingFacet(portfolioFactory, gauge, vault);
        bytes4[] memory claimingSelectors = new bytes4[](5);
        claimingSelectors[0] = DynamicYieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        claimingSelectors[1] = DynamicYieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        claimingSelectors[2] = DynamicYieldBasisLpClaimingFacet.harvestLpFees.selector;
        claimingSelectors[3] = DynamicYieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
        claimingSelectors[4] = DynamicYieldBasisLpClaimingFacet.getDepositInfo.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "DynamicYieldBasisLpClaimingFacet");

        // Lending facet: borrow / pay / topUp against gauge collateral
        DynamicYieldBasisLpLendingFacet lendingFacet =
            new DynamicYieldBasisLpLendingFacet(portfolioFactory, vault, gauge);
        bytes4[] memory lendingSelectors = new bytes4[](4);
        lendingSelectors[0] = DynamicYieldBasisLpLendingFacet.borrow.selector;
        lendingSelectors[1] = DynamicYieldBasisLpLendingFacet.pay.selector;
        lendingSelectors[2] = DynamicYieldBasisLpLendingFacet.setTopUp.selector;
        lendingSelectors[3] = DynamicYieldBasisLpLendingFacet.topUp.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "DynamicYieldBasisLpLendingFacet");

        // Rewards processing: gauge emissions to debt reduction
        DynamicYieldBasisLpRewardsProcessingFacet rewardsProcessingFacet =
            new DynamicYieldBasisLpRewardsProcessingFacet(
                portfolioFactory, swapConfig, gauge, vault, underlying, underlying
            );
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(
            facetRegistry,
            address(rewardsProcessingFacet),
            rewardsProcessingSelectors,
            "DynamicYieldBasisLpRewardsProcessingFacet"
        );

        // Rewards config: distribution policy. Idempotent re-registration is fine.
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(portfolioFactory, swapConfig);
        bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.clearZeroBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");
    }
}

// ETH market (WETH loan vs yb-WETH), step 1 (vault):
// VAULT_UNDERLYING=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 FACTORY_SALT=yieldbasiseth forge script script/portfolio_account/yieldbasis/RedeployVaultDynamicFees.s.sol:RedeployVaultDynamicFees --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
//
// ETH market step 2 (facets), after multisig acceptOwnership + setLoanContract:
// VAULT=<new vault> VAULT_UNDERLYING=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 YIELDBASIS_LP_GAUGE=0xe4e656B5215a82009969219b1bAbB7c0757A3315 FACTORY_SALT=yieldbasiseth forge script script/portfolio_account/yieldbasis/RedeployVaultDynamicFees.s.sol:DynamicYieldBasisLpUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
