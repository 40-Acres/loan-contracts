// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PortfolioFactoryConfigAllowlistTest
 * @dev Focused unit tests for the marketplace allowlist added to
 *      PortfolioFactoryConfig: setAllowedMarketplace / isAllowedMarketplace.
 *      Deploys the config behind an ERC1967 proxy and initializes it with an
 *      arbitrary non-zero factory (the allowlist functions do not touch the
 *      factory binding).
 */
contract PortfolioFactoryConfigAllowlistTest is Test {
    PortfolioFactoryConfig internal config;

    address internal configOwner = address(0xC0FFEE);
    address internal stranger = address(0xBAD);
    address internal factory = address(0xFAC);
    address internal marketplace = address(0x111A);

    function setUp() public {
        // Consistent with the rest of the suite: pin away from epoch boundaries.
        vm.warp(100 weeks);

        PortfolioFactoryConfig impl = new PortfolioFactoryConfig();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        config = PortfolioFactoryConfig(address(proxy));
        config.initialize(configOwner, factory);
    }

    // Default state: nothing allowlisted.
    function test_isAllowedMarketplace_defaultsFalse() public view {
        assertFalse(config.isAllowedMarketplace(marketplace), "default is false");
        assertFalse(config.isAllowedMarketplace(address(0x222B)), "arbitrary addr default false");
    }

    // Owner can set true, then unset back to false; view reflects each toggle.
    function test_setAllowedMarketplace_ownerCanSetAndUnset() public {
        vm.prank(configOwner);
        config.setAllowedMarketplace(marketplace, true);
        assertTrue(config.isAllowedMarketplace(marketplace), "set true reflected");

        vm.prank(configOwner);
        config.setAllowedMarketplace(marketplace, false);
        assertFalse(config.isAllowedMarketplace(marketplace), "unset reflected");
    }

    // Toggling one marketplace must not affect another (mapping isolation).
    function test_setAllowedMarketplace_isolatedPerAddress() public {
        address other = address(0x333C);
        vm.prank(configOwner);
        config.setAllowedMarketplace(marketplace, true);

        assertTrue(config.isAllowedMarketplace(marketplace), "target allowlisted");
        assertFalse(config.isAllowedMarketplace(other), "other untouched");
    }

    // Non-owner cannot set.
    function test_setAllowedMarketplace_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        config.setAllowedMarketplace(marketplace, true);

        // State unchanged.
        assertFalse(config.isAllowedMarketplace(marketplace), "no state change on unauthorized call");
    }

    // Zero-address marketplace is rejected.
    function test_setAllowedMarketplace_revertsOnZeroAddress() public {
        vm.prank(configOwner);
        vm.expectRevert(bytes("Zero address"));
        config.setAllowedMarketplace(address(0), true);
    }
}
