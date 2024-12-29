// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.15;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVoter} from "src/interfaces/IVoter.sol";

contract MockVoter is IVoter {
    address public ve;
    address public token0;
    address public token1;

    constructor(address _votingEscrow, address _token0, address _token1) {
        ve = _votingEscrow;
        token0 = _token0;
        token1 = _token1;
    }

    function vote(
        uint256 _tokenId,
        address[] memory _pools,
        uint256[] memory _amounts
    ) external {
        // do nothing
    }

    /// @notice Claim fees for a given NFT.
    /// @dev Utility to help batch fee claims.
    /// @param _fees    Array of FeesVotingReward contracts to collect from.
    /// @param _tokens  Array of tokens that are used as fees.
    /// @param _tokenId Id of veNFT that you wish to claim fees for.
    function claimFees(
        address[] memory _fees,
        address[][] memory _tokens,
        uint256 _tokenId
    ) external {
        for (uint256 i = 0; i < _fees.length; i++) {
            for (uint256 j = 0; j < _tokens[i].length; j++) {
                // send 50 tokens to the token owner
                address tokenOwner = IERC721(ve).ownerOf(_tokenId);
                // send 50*10^18 tokens to the token owner
                IERC20(token0).transfer(
                    tokenOwner,
                    1 * 10 ** 18
                );
            }
        }
    }


    function claimBribes(
        address[] memory _fees,
        address[][] memory _tokens,
        uint256 _tokenId
    ) external {
        for (uint256 i = 0; i < _fees.length; i++) {
            for (uint256 j = 0; j < _tokens[i].length; j++) {
                // send 50 tokens to the token owner
                address tokenOwner = IERC721(ve).ownerOf(_tokenId);
                // send 50*10^18 tokens to the token owner
                IERC20(token0).transfer(
                    tokenOwner,
                    1 * 10 ** 18
                );
            }
        }
    }
}
