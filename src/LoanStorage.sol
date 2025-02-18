

pragma solidity ^0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

abstract contract LoanStorage is Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:storage:LoanStorage
    struct LoanStorageStruct {
        uint256 _totalWeights;
    }


    // keccak256(abi.encode(uint256(keccak256("erc7201:storage:LoanStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LoanStorageLocation = 0x6dd8e034303aa35aaf3d00b596a4336c7daf449d21fe7bc9975d763227647b00;

    function _getLoanStorage() private pure returns (LoanStorageStruct storage $) {
        assembly {
            $.slot := LoanStorageLocation
        }
    }

    /* Rate Methods */
    function getTotalWeight() public view virtual returns (uint256) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._totalWeights;

    }

    function setTotalWeight(uint256 totalWeights) public onlyOwner {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._totalWeights = totalWeights;
    }

    function addTotalWeight(uint256 weights) internal  {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._totalWeights += weights;
    }

    function subTotalWeight(uint256 weights) internal {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._totalWeights -= weights;
    }

}