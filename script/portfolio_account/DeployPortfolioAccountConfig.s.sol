// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {PortfolioAccountConfig} from "../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../src/facets/account/config/LoanConfig.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SwapConfig} from "../../src/facets/account/config/SwapConfig.sol";

contract PortfolioAccountConfigDeploy is Script {
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    /**
     * @dev Deploys all config contracts atomically to prevent MITM attacks.
     *
     * Each proxy is deployed with initialization data in its constructor,
     * ensuring initialization happens atomically with deployment. This prevents:
     * - Front-running of initialization calls
     * - Hijacking of uninitialized proxies
     *
     * @param mock If true, uses vm.startPrank for testing; if false, assumes broadcast context
     */
    function _deploy(bool mock) internal returns (PortfolioAccountConfig, VotingConfig, LoanConfig, SwapConfig) {
        // Deploy PortfolioAccountConfig atomically (impl + proxy with init in constructor)
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        PortfolioAccountConfig config = PortfolioAccountConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioAccountConfig.initialize, (DEPLOYER_ADDRESS))
            ))
        );

        // Deploy VotingConfig atomically
        VotingConfig votingConfigImpl = new VotingConfig();
        VotingConfig votingConfig = VotingConfig(
            address(new ERC1967Proxy(
                address(votingConfigImpl),
                abi.encodeCall(VotingConfig.initialize, (DEPLOYER_ADDRESS))
            ))
        );

        // Deploy LoanConfig atomically
        LoanConfig loanConfigImpl = new LoanConfig();
        LoanConfig loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (DEPLOYER_ADDRESS))
            ))
        );

        // Deploy SwapConfig atomically
        SwapConfig swapConfigImpl = new SwapConfig();
        SwapConfig swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (DEPLOYER_ADDRESS))
            ))
        );

        // Link configs together (owner-only operations, safe after atomic init)
        if(mock) {
            vm.startPrank(DEPLOYER_ADDRESS);
        }
        config.setVoteConfig(address(votingConfig));
        config.setLoanConfig(address(loanConfig));
        if(mock) {
            vm.stopPrank();
        }
        return (config, votingConfig, loanConfig, swapConfig);
    }
}

contract DeployPortfolioAccountConfig is PortfolioAccountConfigDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        
        _deploy(false);
        
        vm.stopBroadcast();
    }

    function deploy() external returns (PortfolioAccountConfig, VotingConfig, LoanConfig, SwapConfig) {
        (PortfolioAccountConfig portfolioAccountConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = _deploy(true);
        
        return (portfolioAccountConfig, votingConfig, loanConfig, swapConfig);
    }
}


// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 10 --rpc-url $OP_RPC_URL --etherscan-api-key $OPSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 8453 --rpc-url $BASE_RPC_URL --etherscan-api-key $BASESCAN_API_KEY --broadcast --verify --via-ir
