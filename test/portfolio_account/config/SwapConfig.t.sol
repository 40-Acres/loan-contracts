// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title SwapConfigTest
 * @dev Coverage for the approvedVaults and approvedOutputTokens allowlists
 *      added to SwapConfig alongside the existing approvedSwapTargets set.
 */
contract SwapConfigTest is Test {
    SwapConfig internal swapConfig;

    address internal owner = address(0xA110ce);
    address internal nonOwner = address(0xBAD);

    address internal vaultA = address(0xAAAA01);
    address internal vaultB = address(0xAAAA02);
    address internal vaultC = address(0xAAAA03);

    address internal tokenA = address(0xBBBB01);
    address internal tokenB = address(0xBBBB02);
    address internal tokenC = address(0xBBBB03);

    event ApprovedVaultSet(address indexed vault, bool approved);
    event ApprovedOutputTokenSet(address indexed token, bool approved);

    function setUp() public {
        SwapConfig impl = new SwapConfig();
        swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(impl),
                abi.encodeCall(SwapConfig.initialize, (owner))
            ))
        );
    }

    // ─── onlyOwner gates ─────────────────────────────────────────────

    function test_setApprovedVault_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        swapConfig.setApprovedVault(vaultA, true);
    }

    function test_setApprovedOutputToken_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        swapConfig.setApprovedOutputToken(tokenA, true);
    }

    // ─── Vault: add ──────────────────────────────────────────────────

    function test_setApprovedVault_addUpdatesMappingAndList() public {
        vm.prank(owner);
        swapConfig.setApprovedVault(vaultA, true);

        assertTrue(swapConfig.isApprovedVault(vaultA), "vaultA approved");
        assertEq(swapConfig.getApprovedVaultsListLength(), 1, "length=1");
        assertEq(swapConfig.getApprovedVaultAtIndex(0), vaultA, "index 0 = vaultA");

        address[] memory list = swapConfig.getApprovedVaultsList();
        assertEq(list.length, 1, "list length=1");
        assertEq(list[0], vaultA, "list[0] = vaultA");
    }

    function test_setApprovedVault_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(swapConfig));
        emit ApprovedVaultSet(vaultA, true);
        vm.prank(owner);
        swapConfig.setApprovedVault(vaultA, true);

        vm.expectEmit(true, false, false, true, address(swapConfig));
        emit ApprovedVaultSet(vaultA, false);
        vm.prank(owner);
        swapConfig.setApprovedVault(vaultA, false);
    }

    function test_setApprovedVault_remove() public {
        vm.startPrank(owner);
        swapConfig.setApprovedVault(vaultA, true);
        swapConfig.setApprovedVault(vaultB, true);
        swapConfig.setApprovedVault(vaultA, false);
        vm.stopPrank();

        assertFalse(swapConfig.isApprovedVault(vaultA), "vaultA unapproved");
        assertTrue(swapConfig.isApprovedVault(vaultB), "vaultB still approved");
        assertEq(swapConfig.getApprovedVaultsListLength(), 1, "length=1");
        assertEq(swapConfig.getApprovedVaultAtIndex(0), vaultB, "vaultB is only entry");
    }

    function test_setApprovedVault_reAddDoesNotDuplicate() public {
        vm.startPrank(owner);
        swapConfig.setApprovedVault(vaultA, true);
        swapConfig.setApprovedVault(vaultA, true);
        vm.stopPrank();

        assertTrue(swapConfig.isApprovedVault(vaultA), "vaultA still approved");
        assertEq(swapConfig.getApprovedVaultsListLength(), 1, "no duplicate");
    }

    function test_setApprovedVault_multipleAddsAccumulate() public {
        vm.startPrank(owner);
        swapConfig.setApprovedVault(vaultA, true);
        swapConfig.setApprovedVault(vaultB, true);
        swapConfig.setApprovedVault(vaultC, true);
        vm.stopPrank();

        assertEq(swapConfig.getApprovedVaultsListLength(), 3, "length=3");
        address[] memory list = swapConfig.getApprovedVaultsList();
        assertEq(list.length, 3, "list length=3");
        // EnumerableSet preserves insertion order until removal -- assert membership rather than order.
        assertTrue(_contains(list, vaultA), "list has vaultA");
        assertTrue(_contains(list, vaultB), "list has vaultB");
        assertTrue(_contains(list, vaultC), "list has vaultC");
    }

    function test_isApprovedVault_unknownReturnsFalse() public view {
        assertFalse(swapConfig.isApprovedVault(vaultA), "unknown is false");
    }

    function test_getApprovedVaultsList_emptyByDefault() public view {
        address[] memory list = swapConfig.getApprovedVaultsList();
        assertEq(list.length, 0, "empty list");
        assertEq(swapConfig.getApprovedVaultsListLength(), 0, "length=0");
    }

    function test_getApprovedVaultAtIndex_outOfBoundsReverts() public {
        vm.expectRevert();
        swapConfig.getApprovedVaultAtIndex(0);
    }

    // ─── OutputToken: add ────────────────────────────────────────────

    function test_setApprovedOutputToken_addUpdatesMappingAndList() public {
        vm.prank(owner);
        swapConfig.setApprovedOutputToken(tokenA, true);

        assertTrue(swapConfig.isApprovedOutputToken(tokenA), "tokenA approved");
        assertEq(swapConfig.getApprovedOutputTokensListLength(), 1, "length=1");
        assertEq(swapConfig.getApprovedOutputTokenAtIndex(0), tokenA, "index 0 = tokenA");

        address[] memory list = swapConfig.getApprovedOutputTokensList();
        assertEq(list.length, 1, "list length=1");
        assertEq(list[0], tokenA, "list[0] = tokenA");
    }

    function test_setApprovedOutputToken_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(swapConfig));
        emit ApprovedOutputTokenSet(tokenA, true);
        vm.prank(owner);
        swapConfig.setApprovedOutputToken(tokenA, true);

        vm.expectEmit(true, false, false, true, address(swapConfig));
        emit ApprovedOutputTokenSet(tokenA, false);
        vm.prank(owner);
        swapConfig.setApprovedOutputToken(tokenA, false);
    }

    function test_setApprovedOutputToken_remove() public {
        vm.startPrank(owner);
        swapConfig.setApprovedOutputToken(tokenA, true);
        swapConfig.setApprovedOutputToken(tokenB, true);
        swapConfig.setApprovedOutputToken(tokenA, false);
        vm.stopPrank();

        assertFalse(swapConfig.isApprovedOutputToken(tokenA), "tokenA unapproved");
        assertTrue(swapConfig.isApprovedOutputToken(tokenB), "tokenB still approved");
        assertEq(swapConfig.getApprovedOutputTokensListLength(), 1, "length=1");
        assertEq(swapConfig.getApprovedOutputTokenAtIndex(0), tokenB, "tokenB is only entry");
    }

    function test_setApprovedOutputToken_reAddDoesNotDuplicate() public {
        vm.startPrank(owner);
        swapConfig.setApprovedOutputToken(tokenA, true);
        swapConfig.setApprovedOutputToken(tokenA, true);
        vm.stopPrank();

        assertTrue(swapConfig.isApprovedOutputToken(tokenA), "tokenA still approved");
        assertEq(swapConfig.getApprovedOutputTokensListLength(), 1, "no duplicate");
    }

    function test_setApprovedOutputToken_multipleAddsAccumulate() public {
        vm.startPrank(owner);
        swapConfig.setApprovedOutputToken(tokenA, true);
        swapConfig.setApprovedOutputToken(tokenB, true);
        swapConfig.setApprovedOutputToken(tokenC, true);
        vm.stopPrank();

        assertEq(swapConfig.getApprovedOutputTokensListLength(), 3, "length=3");
        address[] memory list = swapConfig.getApprovedOutputTokensList();
        assertEq(list.length, 3, "list length=3");
        assertTrue(_contains(list, tokenA), "list has tokenA");
        assertTrue(_contains(list, tokenB), "list has tokenB");
        assertTrue(_contains(list, tokenC), "list has tokenC");
    }

    function test_isApprovedOutputToken_unknownReturnsFalse() public view {
        assertFalse(swapConfig.isApprovedOutputToken(tokenA), "unknown is false");
    }

    function test_getApprovedOutputTokensList_emptyByDefault() public view {
        address[] memory list = swapConfig.getApprovedOutputTokensList();
        assertEq(list.length, 0, "empty list");
        assertEq(swapConfig.getApprovedOutputTokensListLength(), 0, "length=0");
    }

    function test_getApprovedOutputTokenAtIndex_outOfBoundsReverts() public {
        vm.expectRevert();
        swapConfig.getApprovedOutputTokenAtIndex(0);
    }

    // ─── Isolation: lists do not bleed into each other ───────────────

    function test_vaultAndOutputTokenLists_areIndependent() public {
        vm.startPrank(owner);
        swapConfig.setApprovedVault(vaultA, true);
        swapConfig.setApprovedOutputToken(tokenA, true);
        vm.stopPrank();

        assertTrue(swapConfig.isApprovedVault(vaultA), "vaultA in vault set");
        assertFalse(swapConfig.isApprovedOutputToken(vaultA), "vaultA NOT in token set");

        assertTrue(swapConfig.isApprovedOutputToken(tokenA), "tokenA in token set");
        assertFalse(swapConfig.isApprovedVault(tokenA), "tokenA NOT in vault set");

        assertEq(swapConfig.getApprovedVaultsListLength(), 1, "vault list = 1");
        assertEq(swapConfig.getApprovedOutputTokensListLength(), 1, "token list = 1");
    }

    function test_swapTargetList_unaffectedByVaultOrTokenOps() public {
        vm.startPrank(owner);
        swapConfig.setApprovedSwapTarget(address(0xCAFE), true);
        swapConfig.setApprovedVault(vaultA, true);
        swapConfig.setApprovedOutputToken(tokenA, true);
        vm.stopPrank();

        assertEq(swapConfig.getApprovedSwapTargetsListLength(), 1, "swap target list = 1");
        assertEq(swapConfig.getApprovedSwapTargetAtIndex(0), address(0xCAFE), "swap target intact");
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _contains(address[] memory list, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == needle) return true;
        }
        return false;
    }
}
