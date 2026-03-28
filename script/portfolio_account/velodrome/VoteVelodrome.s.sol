// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {SuperchainVotingConfig} from "../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";

contract VoteVelodrome is Script {
    // Velodrome Optimism addresses
    PortfolioManager public constant PORTFOLIO_MANAGER = PortfolioManager(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);
    address public constant PORTFOLIO_FACTORY = 0x2B2Ad15724924A52cc7C4Db47d54Ab4754ccACA8;
    PortfolioFactoryConfig public constant PORTFOLIO_ACCOUNT_CONFIG = PortfolioFactoryConfig(0x5c7B76E545af04dcFBACAC979c31fAE454fAa680);

    // Superchain pool to vote on
    address public constant SUPERCHAIN_POOL = 0x9f99185d476aA3632dFdB69faE43007E92B7ef7d;

    function run(uint256 tokenId) external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Get the portfolio account address
        address portfolio = PortfolioFactory(PORTFOLIO_FACTORY).portfolioOf(deployer);
        require(portfolio != address(0), "Portfolio not created");
        console.log("Portfolio account:", portfolio);

        vm.startBroadcast(deployerKey);

        // Build vote calldata
        address[] memory pools = new address[](1);
        pools[0] = SUPERCHAIN_POOL;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000; // 100% weight to this pool

        bytes memory voteCalldata = abi.encodeCall(
            SuperchainVotingFacet.vote,
            (tokenId, pools, weights)
        );

        // Execute vote via PortfolioManager multicall
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = voteCalldata;

        address[] memory factories = new address[](1);
        factories[0] = PORTFOLIO_FACTORY;

        PORTFOLIO_MANAGER.multicall(calldatas, factories);

        console.log("Vote submitted for tokenId:", tokenId);
        console.log("Pool:", SUPERCHAIN_POOL);

        vm.stopBroadcast();
    }
}
// forge script script/portfolio_account/velodrome/VoteVelodrome.s.sol:VoteVelodrome --sig "run(uint256)" <TOKEN_ID> --chain-id 10 --rpc-url $OP_RPC_URL --broadcast
