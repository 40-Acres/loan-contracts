// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FortyAcresPortfolioAccount} from "../../../src/accounts/FortyAcresPortfolioAccount.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {SuperchainVotingConfig} from "../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VoteVelodrome is Script {
    // Velodrome Optimism addresses
    PortfolioManager public constant PORTFOLIO_MANAGER = PortfolioManager(0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5);
    address public constant PORTFOLIO_FACTORY = 0x2B2Ad15724924A52cc7C4Db47d54Ab4754ccACA8;
    PortfolioAccountConfig public constant PORTFOLIO_ACCOUNT_CONFIG = PortfolioAccountConfig(0x5c7B76E545af04dcFBACAC979c31fAE454fAa680);

    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);

    // Superchain pool to vote on
    address public constant SUPERCHAIN_POOL = 0x9f99185d476aA3632dFdB69faE43007E92B7ef7d;

    function run(uint256 tokenId) external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Get the portfolio account address
        address portfolio = PortfolioFactory(PORTFOLIO_FACTORY).portfolioOf(deployer);

        // If portfolio doesn't exist yet, compute the CREATE2 address
        // (multicall will auto-create it, but we need the address to fund WETH)
        if (portfolio == address(0)) {
            bytes32 salt = keccak256(abi.encodePacked(deployer));
            bytes memory bytecode = abi.encodePacked(
                type(FortyAcresPortfolioAccount).creationCode,
                abi.encode(PortfolioFactory(PORTFOLIO_FACTORY).facetRegistry())
            );
            portfolio = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                PORTFOLIO_FACTORY,
                salt,
                keccak256(bytecode)
            )))));
            console.log("Portfolio not yet created, predicted address:", portfolio);
        } else {
            console.log("Portfolio account:", portfolio);
        }

        // Check minimum WETH balance requirement
        SuperchainVotingConfig votingConfig = SuperchainVotingConfig(address(PORTFOLIO_ACCOUNT_CONFIG.getVoteConfig()));
        uint256 minimumWeth = votingConfig.getMinimumWethBalance();
        uint256 currentWeth = WETH.balanceOf(portfolio);
        console.log("Minimum WETH required:", minimumWeth);
        console.log("Current WETH in portfolio:", currentWeth);

        vm.startBroadcast(deployerKey);

        // If portfolio doesn't have enough WETH, deposit ETH -> WETH and transfer to portfolio
        if (currentWeth < minimumWeth) {
            uint256 deficit = minimumWeth - currentWeth;
            console.log("WETH deficit, depositing:", deficit);

            // Wrap ETH to WETH
            WETH.deposit{value: deficit}();
            // Transfer WETH to portfolio account
            WETH.transfer(portfolio, deficit);

            console.log("WETH deposited to portfolio");
        }

        // Approve RootMessageBridge to spend WETH from deployer EOA (for cross-chain message fees)
        address ROOT_MESSAGE_BRIDGE = 0xF278761576f45472bdD721EACA19317cE159c011;
        IERC20(address(WETH)).approve(ROOT_MESSAGE_BRIDGE, type(uint256).max);


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

        // Revoke RootMessageBridge approval
        IERC20(address(WETH)).approve(ROOT_MESSAGE_BRIDGE, 0);

        console.log("Vote submitted for tokenId:", tokenId);
        console.log("Pool:", SUPERCHAIN_POOL);

        vm.stopBroadcast();
    }
}
// forge script script/portfolio_account/velodrome/VoteVelodrome.s.sol:VoteVelodrome --sig "run(uint256)" <TOKEN_ID> --chain-id 10 --rpc-url $OP_RPC_URL --broadcast
