// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC4626CollateralManager} from "../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";

/**
 * @title MockRemoveSharesForYieldForwarderFacet
 * @dev Test-only facet that exposes a thin forwarder to
 *      `ERC4626CollateralManager.removeSharesForYield`. The forwarder does NOT
 *      apply any access control of its own — its purpose is to expose the
 *      library function on the diamond so tests can verify the LIBRARY's
 *      `isAuthorizedCaller` gate is what blocks unauthorized calls.
 *
 *      The library uses `msg.sender` (which inside the diamond delegatecall
 *      equals the EOA / contract that called the diamond) to authorize.
 */
contract MockRemoveSharesForYieldForwarderFacet {
    PortfolioFactory public immutable _portfolioFactory;
    address public immutable _vault;

    constructor(address portfolioFactory_, address vault_) {
        _portfolioFactory = PortfolioFactory(portfolioFactory_);
        _vault = vault_;
    }

    /// @dev Forwards directly to the library. The library applies the auth gate.
    function forwardRemoveSharesForYield(uint256 shares) external {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        ERC4626CollateralManager.removeSharesForYield(config, _vault, shares);
    }

    function forwardRemoveSharesForYieldOverloaded(address lpToken, uint256 shares) external {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        ERC4626CollateralManager.removeSharesForYield(config, _vault, lpToken, shares);
    }
}
