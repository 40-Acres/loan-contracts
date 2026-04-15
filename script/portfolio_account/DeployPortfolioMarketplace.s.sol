// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PortfolioMarketplace} from "../../src/facets/marketplace/PortfolioMarketplace.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";

/**
 * @title DeployPortfolioMarketplace
 * @dev Deploys PortfolioMarketplace with CREATE2 using the asset address as salt,
 *      giving deterministic addresses per asset across chains.
 *
 * Environment:
 *   FORTY_ACRES_DEPLOYER - deployer private key
 *   VOTING_ESCROW        - voting escrow address
 *   FEE_BPS              - (optional) protocol fee in bps, defaults to 100
 *   FEE_RECIPIENT        - (optional) fee recipient, defaults to multisig
 *
 * Note: Multisig is set as owner. Configure allowed payment tokens via multisig after deploy.
 *
 * Usage:
 *   forge script script/portfolio_account/DeployPortfolioMarketplace.s.sol:DeployPortfolioMarketplace \
 *     --chain-id <id> --rpc-url <url> --broadcast --verify --via-ir
 */
contract DeployPortfolioMarketplace is Script {
    address public constant MULTISIG_ADDRESS = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    function run() external virtual {
        address votingEscrow = vm.envAddress("VOTING_ESCROW");
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(100));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", MULTISIG_ADDRESS);

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        PortfolioMarketplace marketplace = _deployMarketplace(votingEscrow, feeBps, feeRecipient);

        vm.stopBroadcast();

        console.log("=== PortfolioMarketplace Deployed ===");
        console.log("Address:", address(marketplace));
        console.log("VotingEscrow:", votingEscrow);
        console.log("PortfolioManager:", PORTFOLIO_MANAGER_ADDRESS);
        console.log("Fee BPS:", feeBps);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Chain ID:", block.chainid);
    }

    function _deployMarketplace(
        address votingEscrow,
        uint256 feeBps,
        address feeRecipient
    ) internal returns (PortfolioMarketplace) {
        return new PortfolioMarketplace(
            PORTFOLIO_MANAGER_ADDRESS,
            votingEscrow,
            feeBps,
            feeRecipient,
            MULTISIG_ADDRESS
        );
    }
}

/**
 * @title DeployVeNovaMarketplace
 * @dev Deploys PortfolioMarketplace for veNOVA on Ethereum mainnet.
 *      Allows USDC, WETH, WBTC, and NOVA as payment tokens.
 *
 * Usage:
 *   forge script script/portfolio_account/DeployPortfolioMarketplace.s.sol:DeployVeNovaMarketplace \
 *     --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
 */
contract DeployVeNovaMarketplace is DeployPortfolioMarketplace {
    address public constant VENOVA = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;
    address public constant USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WBTC   = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant NOVA   = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;

    function run() external override {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        PortfolioMarketplace marketplace = _deployMarketplace(VENOVA, 100, MULTISIG_ADDRESS);

        vm.stopBroadcast();

        console.log("=== veNOVA Marketplace Deployed ===");
        console.log("Address:", address(marketplace));
        console.log("VotingEscrow (veNOVA):", VENOVA);
        console.log("Payment Tokens: USDC, WETH, WBTC, NOVA");
        console.log("Chain ID:", block.chainid);
    }
}

/**
 * @title DeployVeBlackMarketplace
 * @dev Deploys PortfolioMarketplace for veBLACK on Avalanche.
 *      Allows BLACK, USDC, WBTC, and WETH as payment tokens.
 *
 * Usage:
 *   forge script script/portfolio_account/DeployPortfolioMarketplace.s.sol:DeployVeBlackMarketplace \
 *     --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
 */
contract DeployVeBlackMarketplace is DeployPortfolioMarketplace {
    address public constant VEBLACK = 0xEac562811cc6abDbB2c9EE88719eCA4eE79Ad763;
    address public constant USDC    = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // Avalanche USDC
    address public constant WETH    = 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB; // WETH.e on Avalanche
    address public constant WBTC    = 0x50b7545627a5162F82A992c33b87aDc75187B218; // WBTC.e on Avalanche
    address public constant BLACK   = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;

    function run() external override {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        PortfolioMarketplace marketplace = _deployMarketplace(VEBLACK, 100, MULTISIG_ADDRESS);

        vm.stopBroadcast();

        console.log("=== veBLACK Marketplace Deployed ===");
        console.log("Address:", address(marketplace));
        console.log("VotingEscrow (veBLACK):", VEBLACK);
        console.log("Payment Tokens: BLACK, USDC, WBTC, WETH");
        console.log("Chain ID:", block.chainid);
    }
}

// Generic (env-driven):
// ASSET=<token> VOTING_ESCROW=<ve> forge script script/portfolio_account/DeployPortfolioMarketplace.s.sol:DeployPortfolioMarketplace \
//   --chain-id <id> --rpc-url <url> --broadcast --verify --via-ir
//
// veNOVA on Ethereum Mainnet:
// forge script script/portfolio_account/DeployPortfolioMarketplace.s.sol:DeployVeNovaMarketplace --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
//
// veBLACK on Avalanche:
// forge script script/portfolio_account/DeployPortfolioMarketplace.s.sol:DeployVeBlackMarketplace --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
