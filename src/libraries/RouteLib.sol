// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

// Enum-driven routing for quoting/buying veNFT listings across venues
library RouteLib {
    // High-level venue route type
    enum BuyRoute {
        InternalWallet,   // wallet-held listing within our orderbook
        InternalLoan,     // loan-custodied listing within our orderbook
        ExternalAdapter   // external marketplace via configured adapter
    }

    // Keys for external markets are chain-specific and configured by governance
    // e.g., bytes32("VEXY"), bytes32("OPENX"), bytes32("SALVOR")
    type adapterKey is bytes32;

    function toKey(string memory name) internal pure returns (adapterKey) {
        return adapterKey.wrap(keccak256(abi.encodePacked(name)));
    }
}


