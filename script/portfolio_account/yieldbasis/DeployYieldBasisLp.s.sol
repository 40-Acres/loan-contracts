// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpRewardsProcessingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title YieldBasisLpDeploy
 * @dev Deploys the YieldBasis LP (gauge staking) facets for a portfolio system.
 *
 * Deploys:
 * - LendingVault: ERC4626 vault that lends USDC directly to portfolio accounts (no Loan intermediary)
 * - YieldBasisLpFacet: deposit/withdraw LP tokens, stake/unstake in gauge, ICollateralFacet
 * - YieldBasisLpClaimingFacet: claim gauge rewards + harvest LP trading fee yield
 * - YieldBasisLpLendingFacet: borrow/repay against gauge share collateral
 * - YieldBasisLpRewardsProcessingFacet: processes claimed rewards against debt/recipients
 * - RewardsConfigFacet: rewards distribution config
 *
 * The gauge address must be provided — this is the ERC4626-compatible YieldBasis gauge
 * that the LP tokens are staked into.
 */
contract YieldBasisLpDeploy is PortfolioFactoryConfigDeploy {
    // Ethereum Mainnet USDC
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // YieldBasis protocol addresses
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;

    // Vault configuration
    uint256 public constant MAX_UTILIZATION_BPS = 8000; // 80%
    uint256 public constant ORIGINATION_FEE_BPS = 80;   // 0.8%

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


        // Deploy configs
        PortfolioManager _portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        PortfolioFactory _portfolioFactory = PortfolioFactory(_portfolioManager.factoryBySalt(keccak256(abi.encodePacked(factorySalt))));

        // ============ Deploy LendingVault ============
        // ERC4626 vault that lends directly — no Loan contract needed
        string memory vaultName = vm.envString("VAULT_NAME");
        require(bytes(vaultName).length != 0, "Set VAULT_NAME env variable");

        string memory vaultSymbol = vm.envString("VAULT_SYMBOL");
        require(bytes(vaultSymbol).length != 0, "Set VAULT_SYMBOL env variable");

        address underlying = vm.envAddress("VAULT_UNDERLYING");
        require(underlying != address(0), "Set VAULT_UNDERLYING env variable");


        LendingVault vaultImpl = new LendingVault();
        bytes memory vaultInitData = abi.encodeCall(
            LendingVault.initialize,
            (underlying, address(_portfolioFactory), MULTISIG_ADDRESS, vaultName, vaultSymbol, MAX_UTILIZATION_BPS, ORIGINATION_FEE_BPS)
        );
        address vaultProxy = address(new ERC1967Proxy(address(vaultImpl), vaultInitData));
        _vault = vaultProxy;


        // Deploy fresh YieldBasisPortfolioFactoryConfig and LoanConfig (no rewards rate/multiplier).
        // YB-specific config holds the protocol-wide stakedGaugeMode flag in its own ERC-7201 slot.
        YieldBasisPortfolioFactoryConfig configImpl = new YieldBasisPortfolioFactoryConfig();
        YieldBasisPortfolioFactoryConfig portfolioFactoryConfig = YieldBasisPortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER_ADDRESS, address(_portfolioFactory)))
            ))
        );

        // Point config to vault (vault IS the lending pool)
        portfolioFactoryConfig.setLoanContract(vaultProxy);
        // portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        console.log("PortfolioFactory at", address(_portfolioFactory));
        console.log("Multisig set PortfolioFactoryConfig to point to vault at", vaultProxy);

        // Deploy LoanConfig (deployer-owned) and wire into PortfolioFactoryConfig.
        if (address(portfolioFactoryConfig.getLoanConfig()) == address(0)) {
            LoanConfig loanConfigImpl = new LoanConfig();
            LoanConfig loanConfig = LoanConfig(address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (DEPLOYER_ADDRESS, 9500, 500, 500))
            )));
            // multiplier and rewardsRate left at 0 - multisig must set these later to enable borrowing
            portfolioFactoryConfig.setLoanConfig(address(loanConfig));
            loanConfig.transferOwnership(MULTISIG_ADDRESS);
            console.log("LoanConfig deployed at", address(loanConfig));
        }

        portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
    }
}

/**
 * @title YieldBasisLpUpgrade
 * @dev Upgrades LP facets for an existing YieldBasis LP deployment
 */
contract YieldBasisLpUpgrade is PortfolioFactoryConfigDeploy {
    // YieldBasis governance / gauge reward token (Ethereum mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        address gauge = vm.envAddress("YIELDBASIS_LP_GAUGE");
        require(gauge != address(0), "Set YIELDBASIS_LP_GAUGE env variable");

        string memory factorySalt = vm.envString("FACTORY_SALT");
        require(bytes(factorySalt).length != 0, "Set FACTORY_SALT env variable");

        PortfolioManager _portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        PortfolioFactory _portfolioFactory = PortfolioFactory(_portfolioManager.factoryBySalt(keccak256(abi.encodePacked(factorySalt))));

        address vault = vm.envAddress("VAULT");
        require(vault != address(0), "Set VAULT env variable");

        address underlying = vm.envAddress("VAULT_UNDERLYING");
        require(underlying != address(0), "Set VAULT_UNDERLYING env variable");

        FacetRegistry facetRegistry = _portfolioFactory.facetRegistry();
        _deployFacets(facetRegistry, address(_portfolioFactory), gauge, vault, underlying, ETH_SWAP_CONFIG);
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
        // Deploy YieldBasisLpFacet (collateral + LP/gauge ops, implements ICollateralFacet)
        // NOTE: third arg is the gauge reward token (YB), NOT the vault underlying.
        // YieldBasis is only deployed on Ethereum mainnet so the YB address is hardcoded.
        // Fourth arg is the underlying asset the LP represents (e.g. WETH for yb-WETH),
        // used by YieldBasisCollateralManager for value denomination.
        // YieldBasisLpFacet lpFacet = new YieldBasisLpFacet(portfolioFactory, gauge, YB, underlying);
        // bytes4[] memory lpSelectors = new bytes4[](9);
        // lpSelectors[0] = YieldBasisLpFacet.deposit.selector;
        // lpSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        // lpSelectors[2] = YieldBasisLpFacet.setStakedMode.selector;
        // lpSelectors[3] = YieldBasisLpFacet.getStakingState.selector;
        // lpSelectors[4] = YieldBasisLpFacet.getTotalLockedCollateral.selector;
        // lpSelectors[5] = YieldBasisLpFacet.getTotalDebt.selector;
        // lpSelectors[6] = YieldBasisLpFacet.getMaxLoan.selector;
        // lpSelectors[7] = YieldBasisLpFacet.enforceCollateralRequirements.selector;
        // lpSelectors[8] = YieldBasisLpFacet.getLTVRatio.selector;
        // _registerFacet(facetRegistry, address(lpFacet), lpSelectors, "YieldBasisLpFacet");

        // // Deploy YieldBasisLpClaimingFacet (gauge rewards + LP fee harvesting)
        // YieldBasisLpClaimingFacet claimingFacet = new YieldBasisLpClaimingFacet(portfolioFactory, gauge, underlying);
        // bytes4[] memory claimingSelectors = new bytes4[](5);
        // claimingSelectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        // claimingSelectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        // claimingSelectors[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
        // claimingSelectors[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
        // claimingSelectors[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
        // _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "YieldBasisLpClaimingFacet");

        // // Deploy YieldBasisLpLendingFacet (borrow/pay against gauge share collateral)
        YieldBasisLpLendingFacet lendingFacet = new YieldBasisLpLendingFacet(portfolioFactory, underlying, gauge, underlying);
        bytes4[] memory lendingSelectors = new bytes4[](2);
        lendingSelectors[0] = YieldBasisLpLendingFacet.borrow.selector;
        lendingSelectors[1] = YieldBasisLpLendingFacet.pay.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "YieldBasisLpLendingFacet");

        // // // Deploy YieldBasisLpRewardsProcessingFacet (YB default token, LP as locked asset via constructor)
        // YieldBasisLpRewardsProcessingFacet rewardsProcessingFacet = new YieldBasisLpRewardsProcessingFacet(
        //     portfolioFactory, swapConfig, gauge, vault, underlying, underlying
        // );
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        // rewardsProcessingSelectors[0] = YieldBasisLpRewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[1] = YieldBasisLpRewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[2] = YieldBasisLpRewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[3] = YieldBasisLpRewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // rewardsProcessingSelectors[4] = YieldBasisLpRewardsProcessingFacet.calculateRoutes.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "YieldBasisLpRewardsProcessingFacet");

        // // // Deploy RewardsConfigFacet
        // RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(portfolioFactory);
        // bytes4[] memory rewardsConfigSelectors = new bytes4[](6);
        // rewardsConfigSelectors[0] = RewardsConfigFacet.setRecipient.selector;
        // rewardsConfigSelectors[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        // _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");
    }
}


contract YieldBasisFacet {
    
}
// forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir


// ETH market (WETH loan vs yb-WETH):
// VAULT_UNDERLYING=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 YIELDBASIS_LP_GAUGE=0xe4e656B5215a82009969219b1bAbB7c0757A3315  FACTORY_SALT=yieldbasiseth VAULT_NAME=40ACRES-ybeth-eth-VAULT VAULT_SYMBOL=40ACRES-YBETH-ETH forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// VAULT_UNDERLYING=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 YIELDBASIS_LP_GAUGE=0xe4e656B5215a82009969219b1bAbB7c0757A3315  FACTORY_SALT=yieldbasiseth VAULT=0x204bEE4cFDAa7b318333bCA8f5612c8164F74Ba3 forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir

// BTC market (WBTC loan vs ybBTC):
// VAULT_UNDERLYING=0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 YIELDBASIS_LP_GAUGE=0xbc56e3edB67b56d598aCE07668b138815F45d7aa FACTORY_SALT=yieldbasisbtc VAULT_NAME=40ACRES-ybbtc-btc-VAULT VAULT_SYMBOL=40ACRES-YBBTC-BTC forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// VAULT_UNDERLYING=0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 YIELDBASIS_LP_GAUGE=0xbc56e3edB67b56d598aCE07668b138815F45d7aa FACTORY_SALT=yieldbasisbtc VAULT=0x9C4c3202d6518dadBC6a7B973646c22A24A06d55 forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir

// cbBTC market (cbBTC loan vs yb-cbBTC):
// VAULT_UNDERLYING=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf YIELDBASIS_LP_GAUGE=0xf3081a2EB8927c0462864eC3FdbE927C842a0893 FACTORY_SALT=yieldbasiscbbtc VAULT_NAME=40ACRES-ybcbbtc-cbbtc-VAULT VAULT_SYMBOL=40ACRES-YBCBBTC-CBBTC forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// VAULT_UNDERLYING=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf YIELDBASIS_LP_GAUGE=0xf3081a2EB8927c0462864eC3FdbE927C842a0893 FACTORY_SALT=yieldbasiscbbtc VAULT=0x1fD7667C14dC1053Fe00d3034270C58aA8A2c8F6 forge script script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol:YieldBasisLpUpgrade --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir