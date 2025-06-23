// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

/// @title PathEncoder - Helper to encode Uniswap V3 swap paths
contract PathEncoder {
    /// @notice Encodes a swap path given token addresses and pool fees
    /// @dev tokens.length must equal fees.length + 1
    /// @param tokens Array of token addresses [token0, token1, token2, ...]
    /// @param fees Array of pool fees between the tokens [fee0, fee1, ...]
    /// @return path Bytes-encoded path (address + fee + address + ...)
    function encodePath(address[] memory tokens, uint24[] memory fees) public pure returns (bytes memory path) {
        require(tokens.length == fees.length + 1, "Invalid path length");

        path = new bytes(0);

        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(
                path,
                tokens[i],                   
                uint24ToBytes3(fees[i])       
            );
        }

        path = abi.encodePacked(path, tokens[tokens.length - 1]);
    }

    /// @dev Helper to convert uint24 to 3-byte array
    function uint24ToBytes3(uint24 value) internal pure returns (bytes3 b) {
        b = bytes3(abi.encodePacked(value));
    }
}