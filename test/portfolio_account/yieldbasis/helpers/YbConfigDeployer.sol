// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {PortfolioFactoryConfigDeploy, DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";

/**
 * @title YbConfigDeployer
 * @dev Test-only helper that deploys a YieldBasisPortfolioFactoryConfig (YB subclass)
 *      via the same atomic init flow as DeployPortfolioFactoryConfig.
 *
 *      Required because YieldBasisLpFacet.getStakedMode() casts the active config
 *      to YieldBasisPortfolioFactoryConfig and reads the YB-specific
 *      `getStakedGaugeMode()` selector. Tests that use the base
 *      DeployPortfolioFactoryConfig deploy the parent contract, which lacks that
 *      selector, so every deposit() call reverts.
 */
contract YbConfigDeployer is DeployPortfolioFactoryConfig {
    function _createConfigImpl() internal override returns (PortfolioFactoryConfig) {
        return PortfolioFactoryConfig(address(new YieldBasisPortfolioFactoryConfig()));
    }

    function deployYb(address factory, address owner)
        external
        returns (YieldBasisPortfolioFactoryConfig, VotingConfig, LoanConfig, SwapConfig)
    {
        (PortfolioFactoryConfig config, VotingConfig votingConfig, LoanConfig loanConfig) =
            _deploy(true, factory, owner);
        SwapConfig swapConfig = _deploySwapConfig(owner);
        return (
            YieldBasisPortfolioFactoryConfig(address(config)),
            votingConfig,
            loanConfig,
            swapConfig
        );
    }
}
