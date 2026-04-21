// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";

/**
 * @title YieldBasisLpDeploy
 * @dev Deploys the YieldBasis LP (gauge staking) facets for a portfolio system.
 *
 * Deploys:
 * - LendingVault: ERC4626 vault that lends USDC directly to portfolio accounts (no Loan intermediary)
 * - YieldBasisLpFacet: deposit/withdraw LP tokens, stake/unstake in gauge, ICollateralFacet
 * - YieldBasisLpClaimingFacet: claim gauge rewards
 * - ERC4626LendingFacet: borrow/repay against gauge share collateral
 *
 * The gauge address must be provided — this is the ERC4626-compatible YieldBasis gauge
 * that the LP tokens are staked into.
 */
contract YieldBasisLpDeploy is PortfolioFactoryConfigDeploy {
    // Ethereum Mainnet USDC
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // YieldBasis protocol addresses
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant GAUGE = address(0); // TODO: Set gauge address

    // Vault configuration
    uint256 public constant MAX_UTILIZATION_BPS = 8000; // 80%
    uint256 public constant ORIGINATION_FEE_BPS = 50;   // 0.5%

    PortfolioManager public _portfolioManager = PortfolioManager(0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec);
    PortfolioFactory public _portfolioFactory;
    address public _vault;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        address gauge = vm.envAddress("YIELDBASIS_LP_GAUGE");
        require(gauge != address(0), "Set YIELDBASIS_LP_GAUGE env variable");

        string memory factorySalt = vm.envString("FACTORY_SALT");
        require(bytes(factorySalt).length != 0, "Set FACTORY_SALT env variable");


        // Deploy factory under existing PortfolioManager
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked(factorySalt))));

        // Deploy configs
        (PortfolioFactoryConfig portfolioFactoryConfig,, LoanConfig loanConfig) = PortfolioFactoryConfigDeploy._deploy(false, address(portfolioFactory));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        _portfolioFactory = portfolioFactory;

        // ============ Deploy LendingVault ============
        // ERC4626 vault that lends directly — no Loan contract needed
        LendingVault vaultImpl = new LendingVault();
        bytes memory vaultInitData = abi.encodeCall(
            LendingVault.initialize,
            (USDC, address(portfolioFactory), msg.sender, "40eth-YB-LP-VAULT", "40ethYBLP", MAX_UTILIZATION_BPS, ORIGINATION_FEE_BPS)
        );
        address vaultProxy = address(new ERC1967Proxy(address(vaultImpl), vaultInitData));
        _vault = vaultProxy;

        // Point config to vault (vault IS the lending pool)
        portfolioFactoryConfig.setLoanContract(vaultProxy);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
    }
}

/**
 * @title YieldBasisLpUpgrade
 * @dev Upgrades LP facets for an existing YieldBasis LP deployment
 */
contract YieldBasisLpUpgrade is PortfolioFactoryConfigDeploy {
    // TODO: Fill in after initial deployment
    address public constant PORTFOLIO_FACTORY = address(0);
    address public constant PORTFOLIO_ACCOUNT_CONFIG = address(0);
    address public constant GAUGE = address(0);
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() external {
        require(PORTFOLIO_FACTORY != address(0), "Set PORTFOLIO_FACTORY address");
        require(PORTFOLIO_ACCOUNT_CONFIG != address(0), "Set PORTFOLIO_ACCOUNT_CONFIG address");
        require(GAUGE != address(0), "Set GAUGE address");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        FacetRegistry facetRegistry = PortfolioFactory(PORTFOLIO_FACTORY).facetRegistry();

        // Upgrade YieldBasisLpFacet
        YieldBasisLpFacet lpFacet = new YieldBasisLpFacet(PORTFOLIO_FACTORY, GAUGE, YB);
        bytes4[] memory lpSelectors = new bytes4[](9);
        lpSelectors[0] = YieldBasisLpFacet.deposit.selector;
        lpSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        lpSelectors[2] = YieldBasisLpFacet.unstake.selector;
        lpSelectors[3] = YieldBasisLpFacet.restake.selector;
        lpSelectors[4] = YieldBasisLpFacet.getStakingState.selector;
        lpSelectors[5] = ICollateralFacet.getTotalLockedCollateral.selector;
        lpSelectors[6] = ICollateralFacet.getTotalDebt.selector;
        lpSelectors[7] = ICollateralFacet.getMaxLoan.selector;
        lpSelectors[8] = ICollateralFacet.enforceCollateralRequirements.selector;
        _registerFacet(facetRegistry, address(lpFacet), lpSelectors, "YieldBasisLpFacet");

        // Upgrade YieldBasisLpClaimingFacet
        YieldBasisLpClaimingFacet claimingFacet = new YieldBasisLpClaimingFacet(PORTFOLIO_FACTORY, GAUGE);
        bytes4[] memory claimingSelectors = new bytes4[](2);
        claimingSelectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        claimingSelectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "YieldBasisLpClaimingFacet");

        // Upgrade ERC4626LendingFacet
        ERC4626LendingFacet lendingFacet = new ERC4626LendingFacet(PORTFOLIO_FACTORY, USDC, GAUGE);
        bytes4[] memory lendingSelectors = new bytes4[](2);
        lendingSelectors[0] = ERC4626LendingFacet.borrow.selector;
        lendingSelectors[1] = ERC4626LendingFacet.pay.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "ERC4626LendingFacet");

        // Upgrade RewardsProcessingFacet and RewardsConfig


        vm.stopBroadcast();
    }
}

// forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
