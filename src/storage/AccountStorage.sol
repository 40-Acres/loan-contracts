// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title AccountStorage
 * @dev Unified storage contract for all user accounts
 * This replaces individual storage per account with a single shared storage contract
 */
contract AccountStorage {
    // Events
    event AccountCreated(address indexed account, address indexed owner);

    // Storage mappings - no redundant tracking
    mapping(address => address) public accountOwners; // account => owner
    mapping(address => address) public userAccounts; // owner => their account

    // Access control
    address public owner;
    mapping(address => bool) public authorizedFactories;

    // Approved addresses that FortyAcresPortfolioAccount can call to
    mapping(address => bool) public approvedAddresses;
    address[] public approvedAddressList;

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "AccountStorage: Only owner");
        _;
    }

    modifier onlyAuthorizedFactory() {
        require(
            authorizedFactories[msg.sender],
            "AccountStorage: Only authorized factory"
        );
        _;
    }

    modifier onlyAccountOwner(address _account) {
        require(
            accountOwners[_account] == msg.sender,
            "AccountStorage: Only account owner"
        );
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @dev Creates a new account entry
     * @param _account The account address
     * @param _owner The account owner
     */
    function createAccount(
        address _account,
        address _owner
    ) external onlyAuthorizedFactory {
        require(
            accountOwners[_account] == address(0),
            "AccountStorage: Account already exists"
        );
        require(_owner != address(0), "AccountStorage: Invalid owner");

        accountOwners[_account] = _owner;
        userAccounts[_owner] = _account;

        emit AccountCreated(_account, _owner);
    }

    /**
     * @dev Gets account owner
     */
    function getAccountOwner(address _account) external view returns (address) {
        address owner = accountOwners[_account];
        require(owner != address(0), "AccountStorage: Account does not exist");
        return owner;
    }

    /**
     * @dev Gets the account for a user
     */
    function getUserAccount(address _user) external view returns (address) {
        return userAccounts[_user];
    }

    /**
     * @dev Checks if account exists (check if owner exists)
     */
    function isUserAccount(address _account) external view returns (bool) {
        return accountOwners[_account] != address(0);
    }

    /**
     * @dev Authorizes a factory
     */
    function authorizeFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "AccountStorage: Invalid factory");
        authorizedFactories[_factory] = true;
    }

    /**
     * @dev Revokes factory authorization
     */
    function revokeFactoryAuthorization(address _factory) external onlyOwner {
        authorizedFactories[_factory] = false;
    }

    /**
     * @dev Transfers contract ownership
     */
    function transferContractOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "AccountStorage: Invalid new owner");
        owner = _newOwner;
    }

    /**
     * @dev Adds an approved address that FortyAcresPortfolioAccount can call to
     * @param _address The address to approve
     */
    function addApprovedAddress(address _address) external onlyOwner {
        require(_address != address(0), "AccountStorage: Invalid address");
        require(
            !approvedAddresses[_address],
            "AccountStorage: Address already approved"
        );

        approvedAddresses[_address] = true;
        approvedAddressList.push(_address);
    }

    /**
     * @dev Removes an approved address
     * @param _address The address to remove from approved list
     */
    function removeApprovedAddress(address _address) external onlyOwner {
        require(
            approvedAddresses[_address],
            "AccountStorage: Address not approved"
        );

        approvedAddresses[_address] = false;

        // Remove from list
        for (uint256 i = 0; i < approvedAddressList.length; i++) {
            if (approvedAddressList[i] == _address) {
                approvedAddressList[i] = approvedAddressList[
                    approvedAddressList.length - 1
                ];
                approvedAddressList.pop();
                break;
            }
        }
    }

    /**
     * @dev Gets all approved addresses
     * @return addresses Array of approved addresses
     */
    function getApprovedAddresses()
        external
        view
        returns (address[] memory addresses)
    {
        return approvedAddressList;
    }

    /**
     * @dev Checks if an address is approved
     * @param _address The address to check
     * @return approved True if the address is approved
     */
    function isApprovedAddress(
        address _address
    ) external view returns (bool approved) {
        return approvedAddresses[_address];
    }
}
