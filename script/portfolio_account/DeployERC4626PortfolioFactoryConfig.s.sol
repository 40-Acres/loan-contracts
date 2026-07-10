// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DeployPortfolioFactoryConfig, PortfolioFactoryConfigDeploy} from "./DeployPortfolioFactoryConfig.s.sol";
import {PortfolioFactoryConfig} from "../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {ERC4626PortfolioFactoryConfig} from "../../src/facets/account/erc4626/ERC4626PortfolioFactoryConfig.sol";

/// @dev Deploys an ERC4626PortfolioFactoryConfig (carries the set-once canonical
///      collateral vault) in place of the base PortfolioFactoryConfig. Used by
///      ERC4626 markets/tests so getCollateralVault() exists and the manager
///      vault-identity guard can be activated.
contract DeployERC4626PortfolioFactoryConfig is DeployPortfolioFactoryConfig {
    function _createConfigImpl() internal override returns (PortfolioFactoryConfig) {
        return new ERC4626PortfolioFactoryConfig();
    }
}
