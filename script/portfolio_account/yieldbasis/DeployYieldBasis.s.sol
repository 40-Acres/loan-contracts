// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioAccountConfigDeploy} from "../DeployPortfolioAccountConfig.s.sol";
import {YieldBasisFacet} from "../../../src/facets/account/yieldbasis/YieldBasisFacet.sol";
import {YieldBasisVotingFacet} from "../../../src/facets/account/yieldbasis/YieldBasisVotingFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {YieldBasisRewardsProcessingFacet} from "../../../src/facets/account/yieldbasis/YieldBasisRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {YieldBasisVotingEscrowAdapter} from "../../../src/adapters/YieldBasisVotingEscrowAdapter.sol";
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
contract YieldBasisRootDeploy is PortfolioAccountConfigDeploy {
    // Ethereum Mainnet USDC
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // YieldBasis Protocol Addresses (Ethereum Mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address public constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;
    address public constant FEE_DISTRIBUTOR = 0xD11b416573EbC59b6B2387DA0D2c0D1b3b1F7A90;

    bytes32 public constant SALT = bytes32(uint256(0x420ac2e));

    PortfolioManager public _portfolioManager = PortfolioManager(0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5);
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        // _portfolioManager = new PortfolioManager{salt: SALT}(DEPLOYER_ADDRESS);
        // require(address(_portfolioManager) == address(0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5), "PortfolioManager deployment failed");
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("yieldbasis-usdc-v2"))));

        // Use inherited _deploy() function from PortfolioAccountConfigDeploy
        (PortfolioAccountConfig portfolioAccountConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = PortfolioAccountConfigDeploy._deploy(false);

        // Set configs at script level - these calls will be broadcast from deployer
        portfolioAccountConfig.setVoteConfig(address(votingConfig));
        portfolioAccountConfig.setLoanConfig(address(loanConfig));

        _portfolioFactory = portfolioFactory;

        // Deploy Loan and Vault atomically using CREATE2 to pre-compute addresses
        // This prevents MITM attacks by initializing in the proxy constructor
        (address loanProxy, address vaultProxy) = _deployLoanAndVaultAtomic(address(portfolioFactory));
        _loanContract = loanProxy;
        Vault vault = Vault(vaultProxy);

        portfolioAccountConfig.setLoanContract(address(_loanContract));

        // Deploy CollateralFacet (required for enforceCollateralRequirements)
        // Note: getCollateralToken excluded because veYB uses TOKEN() not token()
        CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), address(portfolioAccountConfig), VE_YB);
        bytes4[] memory collateralSelectors = new bytes4[](8);
        collateralSelectors[0] = CollateralFacet.addCollateral.selector;
        collateralSelectors[1] = CollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = CollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = CollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = CollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = CollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = CollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = CollateralFacet.enforceCollateralRequirements.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Deploy YieldBasis VotingEscrow Adapter (adapts veYB to CollateralManager's IVotingEscrow interface)
        YieldBasisVotingEscrowAdapter veYBAdapter = new YieldBasisVotingEscrowAdapter(VE_YB);

        // Deploy YieldBasis Faucet (dispenses YB for bootstrapping locks)
        // Note: Faucet needs to be funded with YB tokens after deployment
        // Rate limit: 100 dispenses per hour to prevent abuse
        YieldBasisFaucet faucet = new YieldBasisFaucet(
            address(_portfolioManager),
            YB,
            0.000001 ether,    // dispenseAmount
            10,        // maxDispensesPerWindow
            1 hours     // windowDuration
        );

        // Deploy YieldBasisFacet
        YieldBasisFacet yieldBasisFacet = new YieldBasisFacet(address(portfolioFactory), address(portfolioAccountConfig), VE_YB, YB, address(veYBAdapter), address(faucet));
        bytes4[] memory yieldBasisSelectors = new bytes4[](4);
        yieldBasisSelectors[0] = YieldBasisFacet.createLock.selector;
        yieldBasisSelectors[1] = YieldBasisFacet.increaseLock.selector;
        yieldBasisSelectors[2] = YieldBasisFacet.depositLock.selector;
        yieldBasisSelectors[3] = YieldBasisFacet.enableInfiniteLock.selector;
        _registerFacet(facetRegistry, address(yieldBasisFacet), yieldBasisSelectors, "YieldBasisFacet");

        // Deploy YieldBasisVotingFacet
        YieldBasisVotingFacet yieldBasisVotingFacet = new YieldBasisVotingFacet(address(portfolioFactory), address(portfolioAccountConfig), VE_YB, GAUGE_CONTROLLER, FEE_DISTRIBUTOR);
        bytes4[] memory yieldBasisVotingSelectors = new bytes4[](2);
        yieldBasisVotingSelectors[0] = YieldBasisVotingFacet.vote.selector;
        yieldBasisVotingSelectors[1] = YieldBasisVotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(yieldBasisVotingFacet), yieldBasisVotingSelectors, "YieldBasisVotingFacet");

        // Deploy ERC721ReceiverFacet (needed for veYB NFT transfers)
        ERC721ReceiverFacet erc721ReceiverFacet = new ERC721ReceiverFacet();
        bytes4[] memory erc721ReceiverSelectors = new bytes4[](1);
        erc721ReceiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        _registerFacet(facetRegistry, address(erc721ReceiverFacet), erc721ReceiverSelectors, "ERC721ReceiverFacet");

        // Deploy YieldBasisRewardsProcessingFacet
        YieldBasisRewardsProcessingFacet rewardsProcessingFacet = new YieldBasisRewardsProcessingFacet(address(portfolioFactory), address(portfolioAccountConfig), address(swapConfig), VE_YB, address(veYBAdapter), address(vault));
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](10);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.setRewardsOption.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.getRewardsOption.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.getRewardsOptionPercentage.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.setRewardsToken.selector;
        rewardsProcessingSelectors[5] = RewardsProcessingFacet.setRecipient.selector;
        rewardsProcessingSelectors[6] = RewardsProcessingFacet.setRewardsOptionPercentage.selector;
        rewardsProcessingSelectors[7] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[8] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[9] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "YieldBasisRewardsProcessingFacet");
    }

    /**
     * @dev Deploys Loan and Vault contracts atomically using a factory to prevent MITM attacks.
     *
     * The circular dependency (Vault needs Loan, Loan needs Vault) is resolved by:
     * 1. Deploying implementation contracts separately
     * 2. Deploying an AtomicLoanVaultDeployer factory contract
     * 3. Calling deploy() which handles proxy deployment and initialization in a single transaction
     *
     * This ensures initialization happens atomically with deployment, preventing:
     * - Front-running of initialization calls
     * - Hijacking of uninitialized proxies
     *
     * After deployment, we accept ownership (Loan uses 2-step ownership transfer).
     */
    function _deployLoanAndVaultAtomic(address portfolioFactory) internal returns (address loanProxy, address vaultProxy) {
        // Deploy implementations separately (keeps factory contract small)
        Loan loanImpl = new Loan{salt: keccak256("loan-impl")}();
        LoanV2 loanV2Impl = new LoanV2{salt: keccak256("loan-v2-impl")}();
        Vault vaultImpl = new Vault{salt: keccak256("vault-impl")}();

        // Deploy the atomic deployer factory
        AtomicLoanVaultDeployer deployer = new AtomicLoanVaultDeployer{salt: SALT}();

        // Deploy proxies and initialize atomically in a single transaction
        (loanProxy, vaultProxy) = deployer.deploy(
            address(loanImpl),
            address(loanV2Impl),
            address(vaultImpl),
            USDC,
            portfolioFactory,
            "40eth-USDC-VAULT",
            "40eth-USDC-VAULT"
        );

        // Accept ownership of the loan contract (2-step transfer)
        // The factory initiated the transfer; we complete it here
        LoanV2(loanProxy).acceptOwnership();
    }

    function _trimSelectors(bytes4[] memory selectors, uint256 length) internal pure returns (bytes4[] memory) {
        bytes4[] memory trimmed = new bytes4[](length);
        for (uint256 i = 0; i < length; i++) {
            trimmed[i] = selectors[i];
        }
        return trimmed;
    }

    /**
     * @dev Helper function to register or replace a facet in the FacetRegistry
     */
    function _registerFacet(
        FacetRegistry facetRegistry,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name
    ) internal {
        address oldFacet = facetRegistry.getFacetForSelector(selectors[0]);
        if (oldFacet == address(0)) {
            facetRegistry.registerFacet(facetAddress, selectors, name);
        } else {
            facetRegistry.replaceFacet(oldFacet, facetAddress, selectors, name);
        }
    }
}

/**
 * @title YieldBasisRootUpgrade
 * @dev Upgrades facets for an existing YieldBasis deployment
 */
contract YieldBasisRootUpgrade is PortfolioAccountConfigDeploy {
    // Ethereum Mainnet USDC
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // YieldBasis Protocol Addresses (Ethereum Mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address public constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;
    address public constant FEE_DISTRIBUTOR = 0xD11b416573EbC59b6B2387DA0D2c0D1b3b1F7A90;

    // TODO: Fill in after initial deployment
    address public constant PORTFOLIO_MANAGER = address(0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5);
    address public constant PORTFOLIO_FACTORY = address(0x6D5B539BFf0c1Dc36A6486CB3C3c5d5Ce740e96a);
    address public constant PORTFOLIO_ACCOUNT_CONFIG = address(0x0e23a4eB753334E747CD164C8DEa620e0306D0EC);
    address public constant SWAP_CONFIG = address(0xA4bB092F2049e8eF7bbF1a3cdD7dAdd27b5b77e4);
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

        PortfolioAccountConfig portfolioAccountConfig = PortfolioAccountConfig(PORTFOLIO_ACCOUNT_CONFIG);
        FacetRegistry facetRegistry = PortfolioFactory(PORTFOLIO_FACTORY).facetRegistry();
        YieldBasisFaucet faucet = YieldBasisFaucet(FAUCET);
        YieldBasisVotingEscrowAdapter veYBAdapter = YieldBasisVotingEscrowAdapter(VE_YB_ADAPTER);

        // Deploy CollateralFacet (required for enforceCollateralRequirements)
        // Note: getCollateralToken excluded because veYB uses TOKEN() not token()
        CollateralFacet collateralFacet = new CollateralFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VE_YB);
        bytes4[] memory collateralSelectors = new bytes4[](8);
        collateralSelectors[0] = CollateralFacet.addCollateral.selector;
        collateralSelectors[1] = CollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = CollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = CollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = CollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = CollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = CollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = CollateralFacet.enforceCollateralRequirements.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");
        
        // Deploy YieldBasisFacet
        YieldBasisFacet yieldBasisFacet = new YieldBasisFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VE_YB, YB, address(veYBAdapter), address(faucet));
        bytes4[] memory yieldBasisSelectors = new bytes4[](4);
        yieldBasisSelectors[0] = YieldBasisFacet.createLock.selector;
        yieldBasisSelectors[1] = YieldBasisFacet.increaseLock.selector;
        yieldBasisSelectors[2] = YieldBasisFacet.depositLock.selector;
        yieldBasisSelectors[3] = YieldBasisFacet.enableInfiniteLock.selector;
        _registerFacet(facetRegistry, address(yieldBasisFacet), yieldBasisSelectors, "YieldBasisFacet");

        // Deploy YieldBasisVotingFacet
        YieldBasisVotingFacet yieldBasisVotingFacet = new YieldBasisVotingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VE_YB, GAUGE_CONTROLLER, FEE_DISTRIBUTOR);
        bytes4[] memory yieldBasisVotingSelectors = new bytes4[](2);
        yieldBasisVotingSelectors[0] = YieldBasisVotingFacet.vote.selector;
        yieldBasisVotingSelectors[1] = YieldBasisVotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(yieldBasisVotingFacet), yieldBasisVotingSelectors, "YieldBasisVotingFacet");

        // // Deploy YieldBasisRewardsProcessingFacet
        // require(SWAP_CONFIG != address(0), "Set SWAP_CONFIG address");
        // require(VAULT != address(0), "Set VAULT address");
        // YieldBasisRewardsProcessingFacet rewardsProcessingFacet = new YieldBasisRewardsProcessingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, SWAP_CONFIG, VE_YB, address(veYBAdapter), VAULT);
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](10);
        // rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[1] = RewardsProcessingFacet.setRewardsOption.selector;
        // rewardsProcessingSelectors[2] = RewardsProcessingFacet.getRewardsOption.selector;
        // rewardsProcessingSelectors[3] = RewardsProcessingFacet.getRewardsOptionPercentage.selector;
        // rewardsProcessingSelectors[4] = RewardsProcessingFacet.setRewardsToken.selector;
        // rewardsProcessingSelectors[5] = RewardsProcessingFacet.setRecipient.selector;
        // rewardsProcessingSelectors[6] = RewardsProcessingFacet.setRewardsOptionPercentage.selector;
        // rewardsProcessingSelectors[7] = RewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[8] = RewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[9] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "YieldBasisRewardsProcessingFacet");
    }

    /**
     * @dev Helper function to register or replace a facet in the FacetRegistry
     */
    function _registerFacet(
        FacetRegistry facetRegistry,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name
    ) internal {
        address oldFacet = facetRegistry.getFacetForSelector(selectors[0]);
        if (oldFacet == address(0)) {
            facetRegistry.registerFacet(facetAddress, selectors, name);
        } else {
            facetRegistry.replaceFacet(oldFacet, facetAddress, selectors, name);
        }
    }
}

/**
 * @title AtomicLoanVaultDeployer
 * @dev Factory contract that deploys Loan and Vault proxies atomically in a single transaction.
 *
 * This solves the circular dependency problem:
 * - Vault.initialize() needs the loan address
 * - Loan.initialize() needs the vault address
 *
 * All deployments and initializations happen in a single transaction, preventing:
 * - Front-running of initialization calls
 * - Hijacking of uninitialized proxies
 * - Man-in-the-middle attacks on the deployment process
 *
 * Security: The factory transfers ownership to the caller (msg.sender) after deployment.
 * Since Loan uses Ownable2StepUpgradeable, the caller must call acceptOwnership() on the
 * loan contract to complete the transfer (can be done in the same broadcast).
 *
 * Note: Implementation contracts must be deployed separately and passed to deploy() to
 * keep this contract under the EIP-170 size limit.
 */
contract AtomicLoanVaultDeployer {
    error DeploymentFailed(string reason);

    event AtomicDeployment(
        address indexed loanProxy,
        address indexed vaultProxy,
        address loanImplementation,
        address vaultImplementation,
        address indexed pendingOwner
    );

    /**
     * @dev Deploys Loan and Vault proxies atomically using pre-deployed implementations.
     * @param loanImpl The pre-deployed Loan implementation address
     * @param loanV2Impl The pre-deployed LoanV2 implementation address
     * @param vaultImpl The pre-deployed Vault implementation address
     * @param asset The asset token (e.g., USDC)
     * @param portfolioFactory The portfolio factory address for loan configuration
     * @param vaultName The name for the vault token
     * @param vaultSymbol The symbol for the vault token
     * @return loanProxy The deployed loan proxy address
     * @return vaultProxy The deployed vault proxy address
     *
     * @notice After calling this function, the caller should call:
     *         LoanV2(loanProxy).acceptOwnership() to complete ownership transfer
     */
    function deploy(
        address loanImpl,
        address loanV2Impl,
        address vaultImpl,
        address asset,
        address portfolioFactory,
        string memory vaultName,
        string memory vaultSymbol
    ) external returns (address loanProxy, address vaultProxy) {
        address intendedOwner = msg.sender;

        // Step 1: Deploy loan proxy without initialization first
        // This is necessary because of the circular dependency with vault
        bytes32 loanProxySalt = keccak256("loan-proxy");
        bytes32 vaultProxySalt = keccak256("vault-proxy");

        loanProxy = address(new ERC1967Proxy{salt: loanProxySalt}(
            loanImpl,
            "" // No init data - we'll initialize after vault is deployed
        ));

        // Step 2: Deploy vault proxy with initialization (it knows the loan address)
        bytes memory vaultInitData = abi.encodeCall(
            Vault.initialize,
            (asset, loanProxy, vaultName, vaultSymbol)
        );
        vaultProxy = address(new ERC1967Proxy{salt: vaultProxySalt}(
            vaultImpl,
            vaultInitData
        ));

        // Step 3: Initialize loan with correct vault address
        // Safe because we're still in the same transaction - no one can front-run
        Loan(loanProxy).initialize(vaultProxy, asset);

        // Step 4: Configure loan
        Loan(loanProxy).setPortfolioFactory(portfolioFactory);

        // Step 5: Upgrade to LoanV2
        LoanV2(loanProxy).upgradeToAndCall(loanV2Impl, "");

        // Step 6: Transfer ownership to the intended owner (2-step process)
        // The factory is currently the owner; transfer to the caller
        LoanV2(loanProxy).transferOwnership(intendedOwner);

        emit AtomicDeployment(loanProxy, vaultProxy, loanImpl, vaultImpl, intendedOwner);
    }
}

// forge script script/portfolio_account/yieldbasis/DeployYieldBasis.s.sol:YieldBasisRootDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/yieldbasis/DeployYieldBasis.s.sol:YieldBasisRootUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
