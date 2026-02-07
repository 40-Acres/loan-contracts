// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title PortfolioManagerTest
 * @dev Tests to ensure PortfolioManager deploys the same contracts across different networks
 * using CREATE2 deterministic deployment
 * 
 * Setup:
 * - PortfolioManager is deployed deterministically using CREATE2 in setUp()
 * - This simulates PortfolioManager being at the SAME address across different networks
 * - All tests verify that factories deployed with the same salt will have the same address
 *   when PortfolioManager is at the same address (true cross-network determinism)
 */
contract PortfolioManagerTest is Test {
    PortfolioManager public portfolioManagerBase;
    PortfolioManager public portfolioManagerOp;
    
    uint256 public baseFork;
    uint256 public opFork;
    
    address public constant FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    
    // Test salts - simulating different platforms
    bytes32 public constant SALT_AERODROME = keccak256(abi.encodePacked("aerodrome-usdc"));
    bytes32 public constant SALT_VELODROME = keccak256(abi.encodePacked("velodrome"));
    bytes32 public constant SALT_PHARAOH = keccak256(abi.encodePacked("pharaoh"));
    
    // Salt for deterministic PortfolioManager deployment
    // In production, this would be the same across all networks
    bytes32 public constant MANAGER_SALT = keccak256(abi.encodePacked("PortfolioManager-CrossNetwork"));

    function setUp() public {
        // Create forks of real networks
        baseFork = vm.createFork(vm.envString("BASE_RPC_URL"));
        opFork = vm.createFork(vm.envString("OP_RPC_URL"));
        
        // Deploy PortfolioManager deterministically on Base fork
        vm.selectFork(baseFork);
        address deterministicManagerAddrBase = _deployPortfolioManagerDeterministic(MANAGER_SALT);
        portfolioManagerBase = PortfolioManager(deterministicManagerAddrBase);
        
        // Deploy PortfolioManager deterministically on Optimism fork
        vm.selectFork(opFork);
        address deterministicManagerAddrOp = _deployPortfolioManagerDeterministic(MANAGER_SALT);
        portfolioManagerOp = PortfolioManager(deterministicManagerAddrOp);
        
        // Verify they're at the same address (true cross-network determinism)
        assertEq(
            address(portfolioManagerBase), 
            address(portfolioManagerOp), 
            "PortfolioManager should be at same address across Base and Optimism networks"
        );
    }

    /**
     * @dev Test that deploying with the same salt produces the same factory address across real networks
     * This verifies CREATE2 determinism using real Base and Optimism forks
     */
    function test_DeterministicFactoryDeployment_CrossNetwork() public {
        // Deploy factory on Base fork
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryBase, FacetRegistry registryBase) = portfolioManagerBase.deployFactory(SALT_AERODROME);
        address factoryBaseAddr = address(factoryBase);
        address registryBaseAddr = address(registryBase);
        vm.stopPrank();
        
        // Deploy factory on Optimism fork with same salt
        vm.selectFork(opFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryOp, FacetRegistry registryOp) = portfolioManagerOp.deployFactory(SALT_AERODROME);
        address factoryOpAddr = address(factoryOp);
        address registryOpAddr = address(registryOp);
        vm.stopPrank();
        
        // Verify CREATE2 calculation is correct
        address expectedFactoryBase = _computeFactoryAddress(address(portfolioManagerBase), SALT_AERODROME);
        address expectedFactoryOp = _computeFactoryAddress(address(portfolioManagerOp), SALT_AERODROME);
        
        assertEq(factoryBaseAddr, expectedFactoryBase, "Base factory address should match CREATE2 calculation");
        assertEq(factoryOpAddr, expectedFactoryOp, "Optimism factory address should match CREATE2 calculation");
        
        // Since PortfolioManager is at the same address on both networks (via CREATE2),
        // factories deployed with the same salt should have the same address
        assertEq(
            address(portfolioManagerBase), 
            address(portfolioManagerOp), 
            "PortfolioManager should be at same address on Base and Optimism"
        );
        assertEq(
            factoryBaseAddr, 
            factoryOpAddr, 
            "Same PortfolioManager address + same salt = same factory address across networks"
        );
        assertEq(
            registryBaseAddr, 
            registryOpAddr, 
            "Same PortfolioManager address + same salt = same registry address across networks"
        );
        
        // Verify factories are registered on their respective networks
        vm.selectFork(baseFork);
        assertTrue(portfolioManagerBase.isRegisteredFactory(factoryBaseAddr), "Base factory should be registered");
        
        vm.selectFork(opFork);
        assertTrue(portfolioManagerOp.isRegisteredFactory(factoryOpAddr), "Optimism factory should be registered");
    }

    /**
     * @dev Test that factory addresses can be precomputed before deployment
     * This demonstrates that addresses are deterministic and can be calculated in advance
     */
    function test_PrecomputeFactoryAddress_CrossNetwork() public {
        address managerAddr = address(portfolioManagerBase);
        bytes32 salt = SALT_AERODROME;
        
        // Precompute the factory address (works the same on both networks)
        address precomputedFactoryBase = _computeFactoryAddress(managerAddr, salt);
        address precomputedFactoryOp = _computeFactoryAddress(managerAddr, salt);
        
        // Should be the same since PortfolioManager is at the same address
        assertEq(precomputedFactoryBase, precomputedFactoryOp, "Precomputed addresses should match across networks");
        
        // Deploy on Base and verify it matches
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryBase, ) = portfolioManagerBase.deployFactory(salt);
        vm.stopPrank();
        
        assertEq(address(factoryBase), precomputedFactoryBase, "Base factory should match precomputed address");
        
        // Deploy on Optimism and verify it matches
        vm.selectFork(opFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryOp, ) = portfolioManagerOp.deployFactory(salt);
        vm.stopPrank();
        
        assertEq(address(factoryOp), precomputedFactoryOp, "Optimism factory should match precomputed address");
        
        // Both should be the same
        assertEq(address(factoryBase), address(factoryOp), "Factories should be at same address across networks");
    }

    /**
     * @dev Test that different salts produce different factory addresses
     */
    function test_DeterministicFactoryDeployment_DifferentSalts() public {
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        (PortfolioFactory factory1, ) = portfolioManagerBase.deployFactory(SALT_AERODROME);
        (PortfolioFactory factory2, ) = portfolioManagerBase.deployFactory(SALT_VELODROME);
        (PortfolioFactory factory3, ) = portfolioManagerBase.deployFactory(SALT_PHARAOH);
        
        address factory1Addr = address(factory1);
        address factory2Addr = address(factory2);
        address factory3Addr = address(factory3);
        
        vm.stopPrank();
        
        // All factories should have different addresses
        assertNotEq(factory1Addr, factory2Addr, "Different salts should produce different addresses");
        assertNotEq(factory1Addr, factory3Addr, "Different salts should produce different addresses");
        assertNotEq(factory2Addr, factory3Addr, "Different salts should produce different addresses");
        
        // Verify all are registered
        assertTrue(portfolioManagerBase.isRegisteredFactory(factory1Addr));
        assertTrue(portfolioManagerBase.isRegisteredFactory(factory2Addr));
        assertTrue(portfolioManagerBase.isRegisteredFactory(factory3Addr));



        vm.selectFork(opFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        (PortfolioFactory factoryOp1, ) = portfolioManagerOp.deployFactory(SALT_AERODROME);
        (PortfolioFactory factoryOp2, ) = portfolioManagerOp.deployFactory(SALT_VELODROME);
        (PortfolioFactory factoryOp3, ) = portfolioManagerOp.deployFactory(SALT_PHARAOH);
        
        address factoryOp1Addr = address(factoryOp1);
        address factoryOp2Addr = address(factoryOp2);
        address factoryOp3Addr = address(factoryOp3);
        
        vm.stopPrank();
        
        // All factories should have different addresses
        assertNotEq(factoryOp1Addr, factoryOp2Addr, "Different salts should produce different addresses");
        assertNotEq(factoryOp1Addr, factoryOp3Addr, "Different salts should produce different addresses");
        assertNotEq(factoryOp2Addr, factoryOp3Addr, "Different salts should produce different addresses");
        
    // Verify all are registered
        assertTrue(portfolioManagerOp.isRegisteredFactory(factoryOp1Addr));
        assertTrue(portfolioManagerOp.isRegisteredFactory(factoryOp2Addr));
        assertTrue(portfolioManagerOp.isRegisteredFactory(factoryOp3Addr));


        // all addresses should be same accross networks
        assertEq(factory1Addr, factoryOp1Addr, "Base and Optimism factory addresses should be the same");
        assertEq(factory2Addr, factoryOp2Addr, "Base and Optimism factory addresses should be the same");
        assertEq(factory3Addr, factoryOp3Addr, "Base and Optimism factory addresses should be the same");
    }


    /**
     * @dev Test that FacetRegistry is also deployed deterministically across networks
     */
    function test_DeterministicFacetRegistryDeployment_CrossNetwork() public {
        // Deploy on Base
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryBase, FacetRegistry registryBase) = portfolioManagerBase.deployFactory(SALT_AERODROME);
        address registryBaseAddr = address(registryBase);
        vm.stopPrank();
        
        // Deploy on Optimism
        vm.selectFork(opFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryOp, FacetRegistry registryOp) = portfolioManagerOp.deployFactory(SALT_AERODROME);
        address registryOpAddr = address(registryOp);
        vm.stopPrank();
        
        // Calculate expected FacetRegistry address
        // The registry salt is derived: keccak256(abi.encodePacked(salt, "facet-registry"))
        bytes32 registrySalt = keccak256(abi.encodePacked(SALT_AERODROME, "facet-registry"));
        address expectedRegistryBase = _computeFacetRegistryAddress(address(portfolioManagerBase), registrySalt);
        address expectedRegistryOp = _computeFacetRegistryAddress(address(portfolioManagerOp), registrySalt);
        
        assertEq(registryBaseAddr, expectedRegistryBase, "Base registry address should match CREATE2 calculation");
        assertEq(registryOpAddr, expectedRegistryOp, "Optimism registry address should match CREATE2 calculation");
        
        // Since PortfolioManager is at the same address, registries should also be at the same address
        assertEq(registryBaseAddr, registryOpAddr, "Registries should be at same address across networks");
        
        // Verify registries are tracked on their respective networks
        vm.selectFork(baseFork);
        assertTrue(portfolioManagerBase.isDeployedFacetRegistry(registryBaseAddr));
        
        vm.selectFork(opFork);
        assertTrue(portfolioManagerOp.isDeployedFacetRegistry(registryOpAddr));
    }

    /**
     * @dev Test that the same salt deployed multiple times on the same manager fails
     * (CREATE2 requires the address to be empty)
     */
    function test_DeterministicDeployment_RevertWhen_SameSaltTwice() public {
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        // First deployment succeeds
        portfolioManagerBase.deployFactory(SALT_AERODROME);
        
        // Second deployment with same salt should fail (address already exists)
        vm.expectRevert();
        portfolioManagerBase.deployFactory(SALT_AERODROME);
        
        vm.stopPrank();
    }

    /**
     * @dev Test that factories created with different salts have the same bytecode structure
     * (same contract logic, just different constructor args for FacetRegistry addresses)
     */
    function test_DeterministicDeployment_SameBytecode() public {
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        // Deploy factories with different salts (same PortfolioManager, different salts)
        (PortfolioFactory factory1, FacetRegistry registry1) = portfolioManagerBase.deployFactory(SALT_AERODROME);
        (PortfolioFactory factory2, FacetRegistry registry2) = portfolioManagerBase.deployFactory(SALT_VELODROME);
        
        vm.stopPrank();
        
        // Get bytecode of both factories
        bytes memory code1 = address(factory1).code;
        bytes memory code2 = address(factory2).code;
        
        // Bytecode lengths should match (same contract type)
        assertEq(code1.length, code2.length, "Factory bytecode lengths should match");
        
        // The bytecode should be nearly identical except for the FacetRegistry address
        // embedded in the constructor args. Both should be PortfolioFactory contracts.
        assertGt(code1.length, 0, "Factory 1 should have bytecode");
        assertGt(code2.length, 0, "Factory 2 should have bytecode");
        
        // Verify both factories are PortfolioFactory instances
        assertTrue(address(factory1) != address(0), "Factory 1 should be deployed");
        assertTrue(address(factory2) != address(0), "Factory 2 should be deployed");
        assertEq(address(factory1.facetRegistry()), address(registry1), "Factory 1 should reference correct registry");
        assertEq(address(factory2.facetRegistry()), address(registry2), "Factory 2 should reference correct registry");
    }

    /**
     * @dev Test cross-network scenario using real forks: verify that same PortfolioManager address + same salt
     * produces the same factory address across Base and Optimism
     * 
     * This test demonstrates using real network forks that:
     * 1. PortfolioManager is deployed at the same address on both networks (via CREATE2)
     * 2. Factories deployed with the same salt will have the same address across networks
     * 3. CREATE2 is chain-agnostic (works the same on Base and Optimism)
     */
    function test_CrossNetworkDeterminism_RealForks() public {
        bytes32 salt = SALT_VELODROME; // Use different salt to avoid conflicts
        
        // Verify PortfolioManager is at the same address on both networks
        assertEq(
            address(portfolioManagerBase), 
            address(portfolioManagerOp), 
            "PortfolioManager should be at same address on Base and Optimism"
        );
        
        // Deploy factory on Base fork
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryBase, ) = portfolioManagerBase.deployFactory(salt);
        address factoryBaseAddr = address(factoryBase);
        vm.stopPrank();
        
        // Deploy factory on Optimism fork with same salt
        vm.selectFork(opFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factoryOp, ) = portfolioManagerOp.deployFactory(salt);
        address factoryOpAddr = address(factoryOp);
        vm.stopPrank();
        
        // Verify both factories are at the same address (true cross-network determinism)
        assertEq(
            factoryBaseAddr, 
            factoryOpAddr, 
            "Factories should be at same address across Base and Optimism networks"
        );
        
        // Verify CREATE2 calculation matches on both networks
        address expectedFactoryBase = _computeFactoryAddress(address(portfolioManagerBase), salt);
        address expectedFactoryOp = _computeFactoryAddress(address(portfolioManagerOp), salt);
        
        assertEq(factoryBaseAddr, expectedFactoryBase, "Base factory should match CREATE2 calculation");
        assertEq(factoryOpAddr, expectedFactoryOp, "Optimism factory should match CREATE2 calculation");
    }

    /**
     * @dev Test that factory addresses can be precomputed before deployment on real networks
     */
    function test_PrecomputeFactoryAddress_RealNetwork() public {
        bytes32 salt = SALT_PHARAOH; // Use different salt
        address managerAddr = address(portfolioManagerBase);
        
        // Precompute the factory address (works the same on both networks)
        address precomputedFactory = _computeFactoryAddress(managerAddr, salt);
        
        // Deploy the factory on Base
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory, ) = portfolioManagerBase.deployFactory(salt);
        vm.stopPrank();
        
        // Verify the deployed address matches the precomputed address
        assertEq(address(factory), precomputedFactory, "Deployed factory should match precomputed address");
    }

    /**
     * @dev Test that FacetRegistry addresses can be precomputed on real networks
     */
    function test_PrecomputeFacetRegistryAddress_RealNetwork() public {
        bytes32 salt = SALT_PHARAOH; // Use different salt
        bytes32 registrySalt = keccak256(abi.encodePacked(salt, "facet-registry"));
        address managerAddr = address(portfolioManagerBase);
        
        // Precompute the registry address
        address precomputedRegistry = _computeFacetRegistryAddress(managerAddr, registrySalt);
        
        // Deploy the factory (which deploys the registry) on Base
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (, FacetRegistry registry) = portfolioManagerBase.deployFactory(salt);
        vm.stopPrank();
        
        // Verify the deployed address matches the precomputed address
        assertEq(address(registry), precomputedRegistry, "Deployed registry should match precomputed address");
    }

    /**
     * @dev Helper function to compute factory address using CREATE2 formula
     */
    function _computeFactoryAddress(address deployer, bytes32 salt) internal view returns (address) {
        // Get the bytecode for PortfolioFactory
        // First, we need to know what FacetRegistry address will be used
        // But since FacetRegistry is deployed first, we need to compute it recursively
        bytes32 registrySalt = keccak256(abi.encodePacked(salt, "facet-registry"));
        address registryAddr = _computeFacetRegistryAddress(deployer, registrySalt);
        
        // Now compute factory bytecode with the registry address
        bytes memory factoryBytecode = abi.encodePacked(
            type(PortfolioFactory).creationCode,
            abi.encode(registryAddr)
        );
        
        // CREATE2 address = keccak256(0xff || deployer || salt || keccak256(bytecode))[12:]
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                deployer,
                salt,
                keccak256(factoryBytecode)
            )
        );
        
        return address(uint160(uint256(hash)));
    }

    /**
     * @dev Helper function to compute FacetRegistry address using CREATE2 formula
     */
    function _computeFacetRegistryAddress(address deployer, bytes32 salt) internal view returns (address) {
        address owner = FORTY_ACRES_DEPLOYER;
        
        // Get the bytecode for FacetRegistry
        bytes memory registryBytecode = abi.encodePacked(
            type(FacetRegistry).creationCode,
            abi.encode(owner)
        );
        
        // CREATE2 address = keccak256(0xff || deployer || salt || keccak256(bytecode))[12:]
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                deployer,
                salt,
                keccak256(registryBytecode)
            )
        );
        
        return address(uint160(uint256(hash)));
    }

    /**
     * @dev Helper function to deploy PortfolioManager deterministically using CREATE2
     * This simulates deploying PortfolioManager at the same address across different networks
     */
    function _deployPortfolioManagerDeterministic(bytes32 salt) internal returns (address) {
        // Use address(this) as the deployer (the test contract)
        address deployer = address(this);
        
        // Get the bytecode for PortfolioManager
        bytes memory bytecode = abi.encodePacked(
            type(PortfolioManager).creationCode,
            abi.encode(FORTY_ACRES_DEPLOYER)
        );
        
        // Deploy using CREATE2
        address managerAddr;
        assembly {
            managerAddr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        require(managerAddr != address(0), "PortfolioManager deployment failed");
        
        return managerAddr;
    }

    /**
     * @dev Test that the factory correctly references its FacetRegistry
     */
    function test_FactoryReferencesCorrectRegistry() public {
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        (PortfolioFactory factory, FacetRegistry registry) = portfolioManagerBase.deployFactory(SALT_AERODROME);
        
        vm.stopPrank();
        
        // Verify factory references the correct registry
        assertEq(address(factory.facetRegistry()), address(registry), "Factory should reference correct registry");
    }

    /**
     * @dev Test that multiple factories can be deployed with different salts
     */
    function test_MultipleFactories_DifferentSalts() public {
        vm.selectFork(baseFork);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        (PortfolioFactory factory1, ) = portfolioManagerBase.deployFactory(SALT_AERODROME);
        (PortfolioFactory factory2, ) = portfolioManagerBase.deployFactory(SALT_VELODROME);
        (PortfolioFactory factory3, ) = portfolioManagerBase.deployFactory(SALT_PHARAOH);
        
        vm.stopPrank();
        
        // Verify all factories are registered
        assertEq(portfolioManagerBase.getFactoriesLength(), 3, "Should have 3 factories");
        
        // Verify we can retrieve them
        assertTrue(portfolioManagerBase.isRegisteredFactory(address(factory1)));
        assertTrue(portfolioManagerBase.isRegisteredFactory(address(factory2)));
        assertTrue(portfolioManagerBase.isRegisteredFactory(address(factory3)));
        
        // Verify they're all different
        assertNotEq(address(factory1), address(factory2));
        assertNotEq(address(factory1), address(factory3));
        assertNotEq(address(factory2), address(factory3));
    }
}

