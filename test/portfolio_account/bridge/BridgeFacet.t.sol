// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {BridgeFacet} from "../../../src/facets/account/bridge/BridgeFacet.sol";
import {DeployBridgeFacet} from "../../../script/portfolio_account/facets/DeployBridgeFacet.s.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";

contract BridgeFacetTest is Test {
    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    FacetRegistry public _facetRegistry;
    PortfolioAccountConfig public _portfolioAccountConfig;
    VotingConfig public _votingConfig;
    LoanConfig public _loanConfig;
    BridgeFacet public _bridgeFacet;
    IERC20 public _usdc;
    
    address public constant FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant INK_USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant USDC_SOURCE = 0xd3abC2b515345E47D41C0A1Cd64F8493B80d1ad6;
    address public _user = address(0x1234);
    address public _portfolioAccount;
    uint256 public constant BRIDGE_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        // Fork Ink chain
        uint256 fork = vm.createFork(vm.envString("INK_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(30768635);
        
        // Use real USDC contract
        _usdc = IERC20(INK_USDC);
        
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        // Deploy PortfolioManager and Factory
        _portfolioManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (_portfolioFactory, _facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("velodrome-usdc")))
        );
        
        // Deploy config contracts
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (_portfolioAccountConfig, _votingConfig, _loanConfig, ) = configDeployer.deploy();
        
        // Deploy BridgeFacet
        DeployBridgeFacet bridgeDeployer = new DeployBridgeFacet();
        bridgeDeployer.deploy(
            address(_portfolioFactory),
            address(_portfolioAccountConfig),
            INK_USDC
        );
        
        // Get the deployed BridgeFacet address from the registry
        bytes4 bridgeSelector = BridgeFacet.bridge.selector;
        address bridgeFacetAddress = _facetRegistry.getFacetForSelector(bridgeSelector);
        _bridgeFacet = BridgeFacet(bridgeFacetAddress);
        
        vm.stopPrank();
        
        // Create a portfolio account
        _portfolioAccount = _portfolioFactory.createAccount(_user);
        
        // Transfer USDC from source address to portfolio account
        vm.prank(USDC_SOURCE);
        _usdc.transfer(_portfolioAccount, BRIDGE_AMOUNT);
        
        // Approve TokenMessenger to spend USDC from portfolio account
        vm.prank(_portfolioAccount);
        _usdc.approve(TOKEN_MESSENGER, type(uint256).max);
    }

    function testBridgeFacetDeployment() public {
        assertEq(address(_bridgeFacet._portfolioFactory()), address(_portfolioFactory));
        assertEq(address(_bridgeFacet._portfolioAccountConfig()), address(_portfolioAccountConfig));
        assertEq(address(_bridgeFacet._usdc()), INK_USDC);
        assertEq(_bridgeFacet._destinationDomain(), 2); // Optimism Mainnet
    }

    function testBridge() public {
        uint256 balanceBefore = _usdc.balanceOf(_portfolioAccount);
        assertEq(balanceBefore, BRIDGE_AMOUNT);
        
        vm.prank(_user);
        BridgeFacet(_portfolioAccount).bridge();
        
        // Verify USDC was transferred/burned by TokenMessenger
        uint256 balanceAfter = _usdc.balanceOf(_portfolioAccount);
        assertEq(balanceAfter, 0, "All USDC should be bridged");
    }

}

