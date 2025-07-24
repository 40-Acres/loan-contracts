// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {EntryPoint} from "../src/EntryPoint.sol";

// Mock contract that implements IOwnable
contract MockTarget {
    address public owner;
    uint256 public counter;
    
    constructor(address _owner) {
        owner = _owner;
    }
    
    function setOwner(address _owner) external {
        require(msg.sender == owner, "Not owner");
        owner = _owner;
    }
    
    function increment() external {
        counter++;
    }
    
    function setValue(uint256 _value) external {
        counter = _value;
    }
    
    function revertFunction() external pure {
        revert("Test revert");
    }
    
    function getCallerAddress() external view returns (address) {
        return msg.sender;
    }
}

contract EntryPointTest is Test {
    EntryPoint public entryPoint;
    MockTarget public mockTarget;
    
    address public owner;
    address public authorizedUser;
    address public unauthorizedUser;
    address public newTarget;
    
    event AuthorizedAddressAdded(address indexed user);
    event AuthorizedAddressRemoved(address indexed user);
    
    function setUp() public {
        owner = makeAddr("owner");
        authorizedUser = makeAddr("authorizedUser");
        unauthorizedUser = makeAddr("unauthorizedUser");
        newTarget = makeAddr("newTarget");
        
        // Deploy mock target with owner
        mockTarget = new MockTarget(owner);
        
        // Deploy EntryPoint with mock target
        entryPoint = new EntryPoint(address(mockTarget));
    }
    
    function testConstructor() public {
        assertEq(entryPoint.target(), address(mockTarget));
        assertEq(entryPoint.authorized(authorizedUser), false);
    }
    
    function testRevertsOnSendingValue() public {
        // Authorize user first
        vm.prank(owner);
        entryPoint.authorize(authorizedUser, true);
        
        // give authorized user some ether
        vm.deal(authorizedUser, 1 ether);
        
        // Call increment function through EntryPoint
        vm.prank(authorizedUser);
        (bool success1,) = address(entryPoint).call(
            abi.encodeWithSignature("increment()")
        );
        
        assertTrue(success1);
        assertEq(mockTarget.counter(), 1);

        vm.prank(authorizedUser);
        vm.expectRevert();
        address(entryPoint).call{value: 1}(
            abi.encodeWithSignature("increment()")
        );
        assertEq(mockTarget.counter(), 1);


        vm.prank(authorizedUser);
        (bool success3,) = address(entryPoint).call{value: 0}(
            abi.encodeWithSignature("increment()")
        );
        assertEq(mockTarget.counter(), 2);
        assertTrue(success3);
    }
    
    function testSetTarget() public {
        // Create a new target
        MockTarget newMockTarget = new MockTarget(owner);
        
        // Only owner can set target
        vm.prank(owner);
        entryPoint.setTarget(address(newMockTarget));
        
        assertEq(entryPoint.target(), address(newMockTarget));
    }
    
    function testSetTargetFailsWhenNotOwner() public {
        MockTarget newMockTarget = new MockTarget(owner);
        
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        entryPoint.setTarget(address(newMockTarget));
    }
    
    function testAuthorizeAddress() public {
        // Only owner can authorize
        vm.prank(owner);
        entryPoint.authorize(authorizedUser, true);
        
        assertTrue(entryPoint.authorized(authorizedUser));
    }
    
    function testAuthorizeAddressFailsWhenNotOwner() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        entryPoint.authorize(authorizedUser, true);
    }
    
    function testUnauthorizeAddress() public {
        // First authorize
        vm.prank(owner);
        entryPoint.authorize(authorizedUser, true);
        assertTrue(entryPoint.authorized(authorizedUser));
        
        // Then unauthorize
        vm.prank(owner);
        entryPoint.authorize(authorizedUser, false);
        assertFalse(entryPoint.authorized(authorizedUser));
    }
    
    function testFallbackForwardsCallToTarget() public {
        // Authorize user first
        vm.prank(owner);
        entryPoint.authorize(authorizedUser, true);
        
        // Call increment function through EntryPoint
        vm.prank(authorizedUser);
        (bool success,) = address(entryPoint).call(
            abi.encodeWithSignature("increment()")
        );
        
        assertTrue(success);
        assertEq(mockTarget.counter(), 1);
    }
    
    function testFallbackForwardsCallWithParameters() public {
        // Authorize user first
        vm.prank(owner);
        entryPoint.authorize(authorizedUser, true);
        
        // Call setValue function with parameter
        vm.prank(authorizedUser);
        (bool success,) = address(entryPoint).call(
            abi.encodeWithSignature("setValue(uint256)", 42)
        );
        
        assertTrue(success);
        assertEq(mockTarget.counter(), 42);
    }
    
    function testFallbackFailsWhenNotAuthorized() public {
        // Don't authorize user
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        (bool success,) = address(entryPoint).call(
            abi.encodeWithSignature("increment()")
        );
    }
    
    function testFallbackFailsWhenTargetReverts() public {
        // Authorize user first
        vm.prank(owner);
        entryPoint.authorize(authorizedUser, true);
        
        // Call function that reverts
        vm.prank(authorizedUser);
        vm.expectRevert();
        (bool success,) = address(entryPoint).call(
            abi.encodeWithSignature("revertFunction()")
        );
    }
    
    function testMultipleAuthorizedUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        
        // Authorize multiple users
        vm.startPrank(owner);
        entryPoint.authorize(user1, true);
        entryPoint.authorize(user2, true);
        vm.stopPrank();
        
        // Both should be able to call
        vm.prank(user1);
        (bool success1,) = address(entryPoint).call(
            abi.encodeWithSignature("increment()")
        );
        assertTrue(success1);
        
        vm.prank(user2);
        (bool success2,) = address(entryPoint).call(
            abi.encodeWithSignature("increment()")
        );
        assertTrue(success2);
        
        assertEq(mockTarget.counter(), 2);
    }
    
    function testOwnershipTransferAffectsAuthorization() public {
        address newOwner = makeAddr("newOwner");
        
        // Transfer ownership of target
        vm.prank(owner);
        mockTarget.setOwner(newOwner);
        
        // Old owner should not be able to authorize
        vm.prank(owner);
        vm.expectRevert();
        entryPoint.authorize(authorizedUser, true);
        
        // New owner should be able to authorize
        vm.prank(newOwner);
        entryPoint.authorize(authorizedUser, true);
        assertTrue(entryPoint.authorized(authorizedUser));
    }
    
    function testTargetChangeAffectsOwnership() public {
        address newOwner = makeAddr("newOwner");
        MockTarget newMockTarget = new MockTarget(newOwner);
        
        // Change target
        vm.prank(owner);
        entryPoint.setTarget(address(newMockTarget));
        
        // Old owner should not be able to authorize anymore
        vm.prank(owner);
        vm.expectRevert();
        entryPoint.authorize(authorizedUser, true);
        
        // New target owner should be able to authorize
        vm.prank(newOwner);
        entryPoint.authorize(authorizedUser, true);
        assertTrue(entryPoint.authorized(authorizedUser));
    }
    
    function testFuzzAuthorizeMultipleAddresses(address[] memory addresses) public {
        vm.assume(addresses.length <= 10); // Limit array size for gas
        
        // Authorize all addresses
        vm.startPrank(owner);
        for (uint256 i = 0; i < addresses.length; i++) {
            if (addresses[i] != address(0)) { // Skip zero address
                entryPoint.authorize(addresses[i], true);
                assertTrue(entryPoint.authorized(addresses[i]));
            }
        }
        vm.stopPrank();
    }
    
    function testFuzzSetTarget(address _target) public {
        vm.assume(_target != address(0));
        
        // Create a mock target with the fuzzed address as owner
        // Note: This is a simplified test - in practice you'd need a proper contract
        vm.mockCall(
            _target,
            abi.encodeWithSignature("owner()"),
            abi.encode(owner)
        );
        
        vm.prank(owner);
        entryPoint.setTarget(_target);
        
        assertEq(entryPoint.target(), _target);
    }
}