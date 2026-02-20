// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";

/**
 * @title PortfolioManagerLocalTest
 * @dev Local tests for PortfolioManager's CREATE2 deterministic deployment.
 *      Tests CREATE2 precomputation, different salts, same salt reverts,
 *      factory-registry references — all without RPC.
 *
 *      Cross-network validation (real Base/Optimism forks) remains in
 *      test/fork/accounts/PortfolioManager.t.sol.
 */
contract PortfolioManagerLocalTest is Test {
    PortfolioManager public portfolioManager;

    address public constant FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    // Test salts — simulating different platforms
    bytes32 public constant SALT_AERODROME = keccak256(abi.encodePacked("aerodrome-usdc"));
    bytes32 public constant SALT_VELODROME = keccak256(abi.encodePacked("velodrome"));
    bytes32 public constant SALT_PHARAOH = keccak256(abi.encodePacked("pharaoh"));

    function setUp() public {
        vm.prank(FORTY_ACRES_DEPLOYER);
        portfolioManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
    }

    /**
     * @dev Test that deploying with a salt produces a deterministic factory address
     */
    function test_DeterministicFactoryDeployment() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory, FacetRegistry registry) = portfolioManager.deployFactory(SALT_AERODROME);
        vm.stopPrank();

        // Verify CREATE2 calculation matches
        address expectedFactory = _computeFactoryAddress(address(portfolioManager), SALT_AERODROME);
        bytes32 registrySalt = keccak256(abi.encodePacked(SALT_AERODROME, "facet-registry"));
        address expectedRegistry = _computeFacetRegistryAddress(address(portfolioManager), registrySalt);

        assertEq(address(factory), expectedFactory, "Factory address should match CREATE2 calculation");
        assertEq(address(registry), expectedRegistry, "Registry address should match CREATE2 calculation");

        // Verify factory is registered
        assertTrue(portfolioManager.isRegisteredFactory(address(factory)), "Factory should be registered");
        assertTrue(portfolioManager.isDeployedFacetRegistry(address(registry)), "Registry should be tracked");
    }

    /**
     * @dev Test that factory addresses can be precomputed before deployment
     */
    function test_PrecomputeFactoryAddress() public {
        address managerAddr = address(portfolioManager);

        // Precompute the factory address
        address precomputedFactory = _computeFactoryAddress(managerAddr, SALT_AERODROME);

        // Deploy and verify it matches
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory,) = portfolioManager.deployFactory(SALT_AERODROME);
        vm.stopPrank();

        assertEq(address(factory), precomputedFactory, "Deployed factory should match precomputed address");
    }

    /**
     * @dev Test that FacetRegistry addresses can be precomputed
     */
    function test_PrecomputeFacetRegistryAddress() public {
        bytes32 registrySalt = keccak256(abi.encodePacked(SALT_PHARAOH, "facet-registry"));
        address precomputedRegistry = _computeFacetRegistryAddress(address(portfolioManager), registrySalt);

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (, FacetRegistry registry) = portfolioManager.deployFactory(SALT_PHARAOH);
        vm.stopPrank();

        assertEq(address(registry), precomputedRegistry, "Deployed registry should match precomputed address");
    }

    /**
     * @dev Test that different salts produce different factory addresses
     */
    function test_DifferentSaltsProduceDifferentAddresses() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        (PortfolioFactory factory1,) = portfolioManager.deployFactory(SALT_AERODROME);
        (PortfolioFactory factory2,) = portfolioManager.deployFactory(SALT_VELODROME);
        (PortfolioFactory factory3,) = portfolioManager.deployFactory(SALT_PHARAOH);

        vm.stopPrank();

        assertNotEq(address(factory1), address(factory2), "Different salts should produce different addresses");
        assertNotEq(address(factory1), address(factory3), "Different salts should produce different addresses");
        assertNotEq(address(factory2), address(factory3), "Different salts should produce different addresses");

        // Verify all are registered
        assertTrue(portfolioManager.isRegisteredFactory(address(factory1)));
        assertTrue(portfolioManager.isRegisteredFactory(address(factory2)));
        assertTrue(portfolioManager.isRegisteredFactory(address(factory3)));
    }

    /**
     * @dev Test that the same salt deployed twice on the same manager reverts
     */
    function test_RevertWhen_SameSaltDeployedTwice() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        portfolioManager.deployFactory(SALT_AERODROME);

        vm.expectRevert();
        portfolioManager.deployFactory(SALT_AERODROME);

        vm.stopPrank();
    }

    /**
     * @dev Test that factory references the correct registry
     */
    function test_FactoryReferencesCorrectRegistry() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory, FacetRegistry registry) = portfolioManager.deployFactory(SALT_AERODROME);
        vm.stopPrank();

        assertEq(address(factory.facetRegistry()), address(registry), "Factory should reference correct registry");
    }

    /**
     * @dev Test deploying multiple factories with different salts
     */
    function test_MultipleFactories() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        (PortfolioFactory factory1,) = portfolioManager.deployFactory(SALT_AERODROME);
        (PortfolioFactory factory2,) = portfolioManager.deployFactory(SALT_VELODROME);
        (PortfolioFactory factory3,) = portfolioManager.deployFactory(SALT_PHARAOH);

        vm.stopPrank();

        assertEq(portfolioManager.getFactoriesLength(), 3, "Should have 3 factories");
        assertTrue(portfolioManager.isRegisteredFactory(address(factory1)));
        assertTrue(portfolioManager.isRegisteredFactory(address(factory2)));
        assertTrue(portfolioManager.isRegisteredFactory(address(factory3)));
        assertNotEq(address(factory1), address(factory2));
        assertNotEq(address(factory1), address(factory3));
        assertNotEq(address(factory2), address(factory3));
    }

    /**
     * @dev Test that factories deployed with same contract type have matching bytecode lengths
     */
    function test_SameBytecodeStructure() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        (PortfolioFactory factory1, FacetRegistry registry1) = portfolioManager.deployFactory(SALT_AERODROME);
        (PortfolioFactory factory2, FacetRegistry registry2) = portfolioManager.deployFactory(SALT_VELODROME);

        vm.stopPrank();

        bytes memory code1 = address(factory1).code;
        bytes memory code2 = address(factory2).code;

        assertEq(code1.length, code2.length, "Factory bytecode lengths should match");
        assertGt(code1.length, 0, "Factory 1 should have bytecode");
        assertGt(code2.length, 0, "Factory 2 should have bytecode");

        assertEq(address(factory1.facetRegistry()), address(registry1), "Factory 1 should reference correct registry");
        assertEq(address(factory2.facetRegistry()), address(registry2), "Factory 2 should reference correct registry");
    }

    /**
     * @dev Test that CREATE2 addresses are deterministic by verifying precomputed matches deployed
     *      for both factory and registry from the same salt
     */
    function test_Create2FullDeterminism() public {
        address managerAddr = address(portfolioManager);

        // Precompute both addresses
        address precomputedFactory = _computeFactoryAddress(managerAddr, SALT_VELODROME);
        bytes32 registrySalt = keccak256(abi.encodePacked(SALT_VELODROME, "facet-registry"));
        address precomputedRegistry = _computeFacetRegistryAddress(managerAddr, registrySalt);

        // Deploy
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory, FacetRegistry registry) = portfolioManager.deployFactory(SALT_VELODROME);
        vm.stopPrank();

        // Verify both match
        assertEq(address(factory), precomputedFactory, "Factory should match precomputed");
        assertEq(address(registry), precomputedRegistry, "Registry should match precomputed");

        // Verify they reference each other correctly
        assertEq(address(factory.facetRegistry()), address(registry), "Factory should point to its registry");
    }

    // ============ Helper Functions ============

    function _computeFactoryAddress(address deployer, bytes32 salt) internal pure returns (address) {
        bytes32 registrySalt = keccak256(abi.encodePacked(salt, "facet-registry"));
        address registryAddr = _computeFacetRegistryAddress(deployer, registrySalt);

        bytes memory factoryBytecode = abi.encodePacked(
            type(PortfolioFactory).creationCode,
            abi.encode(registryAddr)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(factoryBytecode))
        );
        return address(uint160(uint256(hash)));
    }

    function _computeFacetRegistryAddress(address deployer, bytes32 salt) internal pure returns (address) {
        bytes memory registryBytecode = abi.encodePacked(
            type(FacetRegistry).creationCode,
            abi.encode(FORTY_ACRES_DEPLOYER)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(registryBytecode))
        );
        return address(uint160(uint256(hash)));
    }
}
