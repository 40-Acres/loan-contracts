// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "src/interfaces/IVotingEscrow.sol";

contract MockVotingEscrow is IVotingEscrow {
    address private _owner;
    uint256 private _tokenId;

    constructor(address owner, uint256 tokenId) {
        _owner = owner;
        _tokenId = tokenId;
    }

    function balanceOf(address owner) external view  returns (uint256 balance) {
        if (_owner == owner) {
            return 1;
        }
        return 0;
    }

    function ownerOf(uint256 tokenId) external view  returns (address owner) {
        if (_tokenId == tokenId) {
            return _owner;
        }
        revert("token does not exist");
    }

    function safeTransferFrom(
        address, /* from */
        address, /* to */
        uint256, /* tokenId */
        bytes calldata /* data */
    ) external pure  {
        revert("Not implemented");
    }

    function safeTransferFrom(
        address, /* from */
        address, /* to */
        uint256 /* tokenId */
    ) external pure   {
        revert("Not implemented");
    }

    function transferFrom(
        address from, /* from */
        address to, /* to */
        uint256 tokenId /* tokenId */
    ) external   {
        if(from  != _owner) {
            revert("Not owner");
        }
        if(tokenId != _tokenId) {
            revert("Not tokenId");
        }
       _owner = to;
    }

    function approve(
        address, /* to */
        uint256 /*tokenId*/
    ) external pure  {
        revert("Not implemented");
    }

    function setApprovalForAll(
        address, /* operator */
        bool /* _approved */
    ) external pure  {
        revert("Not implemented");
    }

    function getApproved(
        uint256 /* tokenId */
    ) external pure returns (address) {
        revert("Not implemented");
    }

    function isApprovedForAll(
        address, /* owner */
        address /* operator */
    ) external pure returns (bool) {
        revert("Not implemented");
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        revert("Not implemented");
    }


    function token() external view returns (address) {
        return address(this);
    }

    function team() external returns (address) {
        return address(this);
    }

    function epoch() external view returns (uint) {
        return 0;
    }
    function point_history(uint loc) external view returns (Point memory) {
        return Point(0, 0, 0, 0);
    }
    function user_point_history(uint tokenId, uint loc) external view returns (Point memory) {
        return Point(0, 0, 0, 0);
    }
    function user_point_epoch(uint tokenId) external view returns (uint) {
        return 0;
    }

    function isApprovedOrOwner(address, uint) external view returns (bool) {
        return true;
    }

    function voting(uint tokenId) external {
        return;
    }

    function abstain(uint tokenId) external {
        return;
    }

    function attach(uint tokenId) external {
        return;
    }

    function detach(uint tokenId) external {
        return;
    }

    function checkpoint() external {
        return;
    }

    function deposit_for(uint tokenId, uint value) external {
        return;
    }

    function create_lock_for(uint, uint, address) external returns (uint) {
        return 0;
    }

    function balanceOfNFT(uint tokenId) external view returns (uint) {
        return 10000;
    }

    function totalSupply() external view returns (uint) {
        return 10000;
    }

    function locked__end(uint tokenId) external view returns (uint) {
        return 1763525791;
    }

}