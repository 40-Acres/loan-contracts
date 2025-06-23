// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;


interface IOwnable {
    function owner() external view returns (address);
}

// EntryPoint contract only accepts transactions from a prefined addresses and sends all transactions to the target
contract EntryPoint {
    address public target;
    mapping(address => bool) public authorized;

    constructor(address _target) {
        target = _target;
    }

    function setTarget(address _target) external {
        require(IOwnable(_target).owner() == msg.sender);
        target = _target;
    }

    function authorize(address _address, bool _authorize) external {
        // Only the owner of the target contract can authorize addresses
        require(IOwnable(target).owner() == msg.sender);
        authorized[_address] = _authorize;
    }

    fallback() external {
        // Only allow calls from authorized addresses
        require(authorized[msg.sender]);
        
        // Forward all calls to the target address
        (bool success, ) = target.call{value: 0}(msg.data);
        require(success);
    }

}