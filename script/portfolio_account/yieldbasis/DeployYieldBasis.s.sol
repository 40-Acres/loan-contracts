// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {veYieldBasisFacet} from "../../../src/facets/account/veyieldbasis/veYieldBasisFacet.sol";
import {veYieldBasisVotingFacet} from "../../../src/facets/account/veyieldbasis/veYieldBasisVotingFacet.sol";
import {DynamicCollateralFacet} from "../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {veYieldBasisRewardsProcessingFacet} from "../../../src/facets/account/veyieldbasis/veYieldBasisRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {veYieldBasisAdapter} from "../../../src/adapters/veYieldBasisAdapter.sol";
import {YieldBasisFaucet} from "../../../src/faucets/YieldBasisFaucet.sol";

/**
 * @title YieldBasisRootDeploy
 * @dev Deploys the full YieldBasis portfolio system on Ethereum mainnet
 *
 * Contract Addresses (Ethereum Mainnet):
 * - YB Token: 0x01791F726B4103694969820be083196cC7c045fF
 * - veYB: 0x8235c179E9e84688FBd8B12295EfC26834dAC211
 * - GaugeController: 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21
 * - FeeDistributor: 0xD11b416573EbC59b6B2387DA0D2c0D1b3b1F7A90
 */
contract YieldBasisRootDeploy is PortfolioFactoryConfigDeploy {
    // Ethereum Mainnet USDC
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // YieldBasis Protocol Addresses (Ethereum Mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address public constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;
    address public constant FEE_DISTRIBUTOR = 0xD11b416573EbC59b6B2387DA0D2c0D1b3b1F7A90;

    PortfolioManager public _portfolioManager = PortfolioManager(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);
    PortfolioFactory public _portfolioFactory;
    DynamicFeesVault public _vault;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        // _portfolioManager = new PortfolioManager{salt: SALT}(DEPLOYER_ADDRESS);
        // require(address(_portfolioManager) == address(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9), "PortfolioManager deployment failed");
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("yieldbasis-usdc"))));

        // Deploy config contracts (no VotingConfig needed for YieldBasis)
        // Initialize with deployer as owner so we can configure, then transfer to multisig
        address deployer = vm.addr(vm.envUint("FORTY_ACRES_DEPLOYER"));

        PortfolioFactoryConfig configImpl = new PortfolioFactoryConfig();
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (deployer, address(portfolioFactory)))
            ))
        );

        LoanConfig loanConfigImpl = new LoanConfig();
        LoanConfig loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (deployer, 70_00, 5_00, 1_00))
            ))
        );

        SwapConfig swapConfigImpl = new SwapConfig();
        SwapConfig swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (deployer))
            ))
        );

        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        _portfolioFactory = portfolioFactory;

        // Deploy DynamicFeesVault (implements ILendingPool — no separate Loan contract needed)
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(DynamicFeesVault.initialize, (USDC, "40eth-USDC-DYNAMIC-VAULT", "40eth-USDC-DV", address(portfolioFactory), 8000))
        );
        _vault = DynamicFeesVault(address(vaultProxy));

        portfolioFactoryConfig.setLoanContract(address(_vault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Deploy YieldBasis VotingEscrow Adapter (adapts veYB to CollateralManager's IVotingEscrow interface)
        veYieldBasisAdapter veYBAdapter = new veYieldBasisAdapter(VE_YB);

        // Deploy YieldBasis Faucet (dispenses YB for bootstrapping locks)
        // Note: Faucet needs to be funded with YB tokens after deployment
        YieldBasisFaucet faucet = new YieldBasisFaucet(
            address(_portfolioManager),
            YB,
            1     // dispenseAmount: 1 wei of YB
        );

        // Facets are deployed separately via YieldBasisRootUpgrade

        // Transfer ownership to multisig (all use Ownable2Step — multisig must acceptOwnership)
        portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
        loanConfig.transferOwnership(MULTISIG_ADDRESS);
        swapConfig.transferOwnership(MULTISIG_ADDRESS);
        _vault.transferOwnership(MULTISIG_ADDRESS);
        facetRegistry.transferOwnership(MULTISIG_ADDRESS);
        faucet.transferOwnership(MULTISIG_ADDRESS);

        console.log("=== Deployed Addresses ===");
        console.log("PortfolioFactory:", address(portfolioFactory));
        console.log("FacetRegistry:", address(facetRegistry));
        console.log("PortfolioFactoryConfig:", address(portfolioFactoryConfig));
        console.log("LoanConfig:", address(loanConfig));
        console.log("SwapConfig:", address(swapConfig));
        console.log("DynamicFeesVault:", address(_vault));
        console.log("veYBAdapter:", address(veYBAdapter));
        console.log("Faucet:", address(faucet));
        console.log("=== Ownership transferred to multisig (pending acceptance) ===");
    }

}

/**
 * @title YieldBasisRootUpgrade
 * @dev Upgrades facets for an existing YieldBasis deployment
 */
contract YieldBasisRootUpgrade is PortfolioFactoryConfigDeploy {
    // Ethereum Mainnet USDC
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // YieldBasis Protocol Addresses (Ethereum Mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address public constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;
    address public constant FEE_DISTRIBUTOR = 0xD11b416573EbC59b6B2387DA0D2c0D1b3b1F7A90;

    // TODO: Fill in after initial deployment
    address public constant PORTFOLIO_MANAGER = address(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);
    address public constant PORTFOLIO_FACTORY = address(0x6D5B539BFf0c1Dc36A6486CB3C3c5d5Ce740e96a);
    address public constant PORTFOLIO_ACCOUNT_CONFIG = address(0x0e23a4eB753334E747CD164C8DEa620e0306D0EC);
    address public constant VAULT = address(0x24914636DAb84236Cb7D4394cD25D15Ec6e3Bd50);
    address public constant FAUCET = address(0xcaa4a36B5179672719256Df77E0943146C548193);
    address public constant VE_YB_ADAPTER = address(0x54F394ebC8Aa2b71f431Dc90f7675b7360465464);

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgradeFacets();
        vm.stopBroadcast();
    }

    function upgradeFacets() internal {
        require(PORTFOLIO_FACTORY != address(0), "Set PORTFOLIO_FACTORY address");
        require(PORTFOLIO_ACCOUNT_CONFIG != address(0), "Set PORTFOLIO_ACCOUNT_CONFIG address");

        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(PORTFOLIO_ACCOUNT_CONFIG);
        FacetRegistry facetRegistry = PortfolioFactory(PORTFOLIO_FACTORY).facetRegistry();
        YieldBasisFaucet faucet = YieldBasisFaucet(FAUCET);
        veYieldBasisAdapter veYBAdapter = veYieldBasisAdapter(VE_YB_ADAPTER);

        // Deploy DynamicCollateralFacet (uses DynamicCollateralManager storage for DynamicFeesVault)
        // Note: getCollateralToken excluded because veYB uses TOKEN() not token()
        DynamicCollateralFacet collateralFacet = new DynamicCollateralFacet(PORTFOLIO_FACTORY, VE_YB);
        bytes4[] memory collateralSelectors = new bytes4[](8);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[6] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSelectors[7] = BaseCollateralFacet.getLTVRatio.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "DynamicCollateralFacet");

        // Deploy veYieldBasisFacet
        veYieldBasisFacet yieldBasisFacet = new veYieldBasisFacet(PORTFOLIO_FACTORY, VE_YB, YB, address(veYBAdapter), address(faucet));
        bytes4[] memory yieldBasisSelectors = new bytes4[](4);
        yieldBasisSelectors[0] = veYieldBasisFacet.createLock.selector;
        yieldBasisSelectors[1] = veYieldBasisFacet.increaseLock.selector;
        yieldBasisSelectors[2] = veYieldBasisFacet.depositLock.selector;
        yieldBasisSelectors[3] = veYieldBasisFacet.onERC721Received.selector;
        _registerFacet(facetRegistry, address(yieldBasisFacet), yieldBasisSelectors, "veYieldBasisFacet");

        // Deploy veYieldBasisVotingFacet
        veYieldBasisVotingFacet yieldBasisVotingFacet = new veYieldBasisVotingFacet(PORTFOLIO_FACTORY, VE_YB, GAUGE_CONTROLLER);
        bytes4[] memory yieldBasisVotingSelectors = new bytes4[](2);
        yieldBasisVotingSelectors[0] = veYieldBasisVotingFacet.vote.selector;
        yieldBasisVotingSelectors[1] = veYieldBasisVotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(yieldBasisVotingFacet), yieldBasisVotingSelectors, "veYieldBasisVotingFacet");

        // // Deploy veYieldBasisRewardsProcessingFacet
        // require(SWAP_CONFIG != address(0), "Set SWAP_CONFIG address");
        // require(VAULT != address(0), "Set VAULT address");
        // veYieldBasisRewardsProcessingFacet rewardsProcessingFacet = new veYieldBasisRewardsProcessingFacet(PORTFOLIO_FACTORY, SWAP_CONFIG, VE_YB, address(veYBAdapter), VAULT);
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        // rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "veYieldBasisRewardsProcessingFacet");
        //
        // // Deploy RewardsConfigFacet
        // RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(PORTFOLIO_FACTORY);
        // bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        // rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        // rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        // rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        // _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");
    }

}

// forge script script/portfolio_account/yieldbasis/DeployYieldBasis.s.sol:YieldBasisRootDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/yieldbasis/DeployYieldBasis.s.sol:YieldBasisRootUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
