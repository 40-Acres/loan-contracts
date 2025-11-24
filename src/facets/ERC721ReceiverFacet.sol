// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC721Receiver} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

// Minimal facet to allow the diamond to receive ERC721 via safeTransferFrom
contract ERC721ReceiverFacet is IERC721Receiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}


