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

contract PortfolioAccountConfigDeploy is Script {
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    function _deploy(bool mock) internal returns (PortfolioAccountConfig, VotingConfig, LoanConfig) {
        // Deploy PortfolioAccountConfig behind proxy
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), "");
        PortfolioAccountConfig config = PortfolioAccountConfig(address(configProxy));
        config.initialize(DEPLOYER_ADDRESS);
        
        // Deploy VotingConfig behind proxy
        VotingConfig votingConfigImpl = new VotingConfig();
        ERC1967Proxy votingConfigProxy = new ERC1967Proxy(address(votingConfigImpl), "");
        VotingConfig votingConfig = VotingConfig(address(votingConfigProxy));
        votingConfig.initialize(DEPLOYER_ADDRESS);
        
        // Deploy LoanConfig behind proxy
        LoanConfig loanConfigImpl = new LoanConfig();
        ERC1967Proxy loanConfigProxy = new ERC1967Proxy(address(loanConfigImpl), "");
        LoanConfig loanConfig = LoanConfig(address(loanConfigProxy));
        loanConfig.initialize(DEPLOYER_ADDRESS);
        
        if(mock) {
            vm.startPrank(DEPLOYER_ADDRESS);
        }
        config.setVoteConfig(address(votingConfig));
        config.setLoanConfig(address(loanConfig));
        if(mock) {
            vm.stopPrank();
        }
        return (config, votingConfig, loanConfig);
    }
}

contract DeployPortfolioAccountConfig is PortfolioAccountConfigDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        
        _deploy(false);
        
        vm.stopBroadcast();
    }

    function deploy() external returns (PortfolioAccountConfig, VotingConfig, LoanConfig) {
        (PortfolioAccountConfig portfolioAccountConfig, VotingConfig votingConfig, LoanConfig loanConfig) = _deploy(true);
        
        return (portfolioAccountConfig, votingConfig, loanConfig);
    }
}


// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 10 --rpc-url $OP_RPC_URL --etherscan-api-key $OPSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 8453 --rpc-url $BASE_RPC_URL --etherscan-api-key $BASESCAN_API_KEY --broadcast --verify --via-ir
