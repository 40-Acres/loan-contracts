// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../src/facets/account/config/LoanConfig.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SwapConfig} from "../../src/facets/account/config/SwapConfig.sol";

contract PortfolioFactoryConfigDeploy is Script {
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG_ADDRESS = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    bytes32 public constant SALT = bytes32(uint256(0x0000000000000000000000000000000000000000000000000e000005c6c57005));


    address public constant AERO_VOTING_CONFIG =0xdebEE5c3DFa953DBb1a48819dfF3cC9c12226E0C;
    address public constant NOVA_VOTING_CONFIG = 0x8a66bC8F873C541043347fC9D712F8d4a0C6730E;

    address public constant BASE_SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;
    address public constant OP_SWAP_CONFIG = 0x0000000000000000000000000000000000000000;
    address public constant ETH_SWAP_CONFIG = 0xD504Da3Ae86Aa3233871dbc8ae3Eb38824138F7C;

    address public constant VEAERO_MARKETPLACE = 0xA62C351b3DEDAB4C3e0Cab59B1bc9E5e3097BdF6;
    address public constant VENOVA_MARKETPLACE = 0xb71d66583A420cbc77641759c1a6E6F3FB68CeB2;
    
    address public constant AERO_USDC_VAULT = 0xB99B6dF96d4d5448cC0a5B3e0ef7896df9507Cf5;

    function _createConfigImpl() internal virtual returns (PortfolioFactoryConfig) {
        return new PortfolioFactoryConfig();
    }

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
    function _deploy(bool mock, address factory) internal returns (PortfolioFactoryConfig, VotingConfig, LoanConfig) {
        return _deploy(mock, factory, MULTISIG_ADDRESS);
    }

    // VotingConfig is per-collateral: each PortfolioFactory deployment gets its own
    // SwapConfig is per-network: deploy separately via _deploySwapConfig() for initial network setup
    function _deploy(bool mock, address factory, address owner) internal returns (PortfolioFactoryConfig, VotingConfig, LoanConfig) {
        require(factory != address(0), "Factory required");
        // Deploy PortfolioFactoryConfig atomically (impl + proxy with init in constructor)
        PortfolioFactoryConfig configImpl = _createConfigImpl();
        PortfolioFactoryConfig config = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (owner, factory))
            ))
        );

        // Deploy VotingConfig atomically (per-collateral)
        VotingConfig votingConfigImpl = new VotingConfig();
        VotingConfig votingConfig = VotingConfig(
            address(new ERC1967Proxy(
                address(votingConfigImpl),
                abi.encodeCall(VotingConfig.initialize, (owner))
            ))
        );

        // Deploy LoanConfig atomically
        LoanConfig loanConfigImpl = new LoanConfig();
        LoanConfig loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (owner, 20_00, 5_00, 1_00))
            ))
        );

        // Link configs together (owner-only operations, safe after atomic init)
        if(mock) {
            vm.startPrank(owner);
        }
        config.setVoteConfig(address(votingConfig));
        config.setLoanConfig(address(loanConfig));
        if(mock) {
            vm.stopPrank();
        }
        return (config, votingConfig, loanConfig);
    }

    /// @dev Deploy a standalone SwapConfig. Call once per network, then share across all factories.
    function _deploySwapConfig(address owner) internal returns (SwapConfig) {
        SwapConfig swapConfigImpl = new SwapConfig();
        return SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (owner))
            ))
        );
    }

    /**
     * @dev Helper function to register or replace a facet in the FacetRegistry.
     * Loops through all selectors to find an existing facet, handling cases where
     * new selectors are added during upgrades.
     */
    function _registerFacet(
        FacetRegistry facetRegistry,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name
    ) internal {
        address oldFacet;
        for (uint256 i = 0; i < selectors.length; i++) {
            address existingFacet = facetRegistry.getFacetForSelector(selectors[i]);
            if (existingFacet != address(0)) {
                oldFacet = existingFacet;
            }
        }

        // If broadcaster is not the registry owner, output Safe tx data instead
        address owner = facetRegistry.owner();
        if (owner != msg.sender) {
            console.log("=== Safe Transaction Data ===");
            console.log("To (FacetRegistry):", address(facetRegistry));
            if (oldFacet == address(0)) {
                console.log("Function: registerFacet(address,bytes4[],string)");
                console.log("Calldata:");
                console.logBytes(abi.encodeWithSelector(
                    FacetRegistry.registerFacet.selector, facetAddress, selectors, name
                ));
            } else {
                console.log("Function: replaceFacet(address,address,bytes4[],string)");
                console.log("Old Facet:", oldFacet);
                console.log("Calldata:");
                console.logBytes(abi.encodeWithSelector(
                    FacetRegistry.replaceFacet.selector, oldFacet, facetAddress, selectors, name
                ));
            }
            console.log("New Facet:", facetAddress);
            console.log("Facet Name:", name);
            console.log("Selectors:");
            for (uint256 i = 0; i < selectors.length; i++) {
                console.logBytes4(selectors[i]);
            }
            console.log("=============================");
            return;
        }

        if (oldFacet == address(0)) {
            facetRegistry.registerFacet(facetAddress, selectors, name);
        } else {
            facetRegistry.replaceFacet(oldFacet, facetAddress, selectors, name);
        }
    }
}

contract DeployPortfolioFactoryConfig is PortfolioFactoryConfigDeploy {
    function run(address factory) external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        _deploy(false, factory);

        vm.stopBroadcast();
    }

    function deploy(address factory) external returns (PortfolioFactoryConfig, VotingConfig, LoanConfig, SwapConfig) {
        (PortfolioFactoryConfig config, VotingConfig votingConfig, LoanConfig loanConfig) = _deploy(true, factory);
        SwapConfig swapConfig = _deploySwapConfig(MULTISIG_ADDRESS);
        return (config, votingConfig, loanConfig, swapConfig);
    }

    function deploy(address factory, address owner) external returns (PortfolioFactoryConfig, VotingConfig, LoanConfig, SwapConfig) {
        (PortfolioFactoryConfig config, VotingConfig votingConfig, LoanConfig loanConfig) = _deploy(true, factory, owner);
        SwapConfig swapConfig = _deploySwapConfig(owner);
        return (config, votingConfig, loanConfig, swapConfig);
    }
}


// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 10 --rpc-url $OP_RPC_URL --etherscan-api-key $OPSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 8453 --rpc-url $BASE_RPC_URL --etherscan-api-key $BASESCAN_API_KEY --broadcast --verify --via-ir
