// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {LoanConfig} from "./LoanConfig.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";

/**
 * @title PortfolioAccountConfig
 */
contract PortfolioAccountConfig is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address owner) initializer public {
        __Ownable_init(owner); 
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct PortfolioAccountConfigData {
        mapping(address => bool) approvedContracts;
        address loanContract;
        address voteConfig;
        LoanConfig loanConfig;
        uint256 minimumCollateral;
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.PortfolioAccountConfig");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getPortfolioAccountConfig() internal pure returns (PortfolioAccountConfigData storage collateralStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            collateralStorage.slot := position
        }
    }

    function setApprovedContract(address addr, bool approved) public onlyOwner {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        collateralStorage.approvedContracts[addr] = approved;
    }

    function isApprovedContract(address addr) public view returns (bool) {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        return collateralStorage.approvedContracts[addr];
    }

    function setLoanContract(address addr) public onlyOwner {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        collateralStorage.loanContract = addr;
    }

    function getLoanContract() public view returns (address) {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        return collateralStorage.loanContract;
    }

    function setVoteConfig(address addr) public onlyOwner {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        collateralStorage.voteConfig = addr;
    }

    function getVoteConfig() public view returns (address) {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        return collateralStorage.voteConfig;
    }

    function setLoanConfig(address addr) public onlyOwner {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        collateralStorage.loanConfig = LoanConfig(addr);
    }

    function getLoanConfig() public view returns (LoanConfig) {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        return collateralStorage.loanConfig;
    }

    function getDebtToken() public view returns (address) {
        return address(ILoan(getLoanContract())._asset());
    }

    function setMinimumCollateral(uint256 minimumCollateral) public onlyOwner {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        collateralStorage.minimumCollateral = minimumCollateral;
    }

    function getMinimumCollateral() public view returns (uint256) {
        PortfolioAccountConfigData storage collateralStorage = _getPortfolioAccountConfig();
        return collateralStorage.minimumCollateral;
    }

    function getVault() public view returns (address) {
        return ILoan(getLoanContract())._vault();
    }
}