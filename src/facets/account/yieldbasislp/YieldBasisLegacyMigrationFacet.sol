// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {DynamicYieldBasisCollateralManager} from "./DynamicYieldBasisCollateralManager.sol";

/**
 * @title YieldBasisLegacyMigrationFacet
 * @dev One-shot facet that seeds DynamicYieldBasisCollateralManager storage
 *      for accounts holding physical YieldBasis LP / gauge balances that
 *      predate the dynamic-manager refactor.
 *
 *      Lifecycle: registered, executed across the tracked account set, and
 *      removed in a single atomic Safe multiSend. The selector is never
 *      meant to live on the diamond longer than one transaction.
 *
 *      No authorization modifier. Safety comes from:
 *        1. The ephemeral selector lifetime (atomic Safe batch)
 *        2. The data.shares == 0 replay guard
 *        3. Routing through DynamicYieldBasisCollateralManager.addCollateral,
 *           which already enforces actualBalance >= requiredBalance against
 *           the account's real LP + gauge holdings
 *
 *      The library handles snapshot, depositedAssetValue stamp, event emit,
 *      and PortfolioFactoryConfig tracker notify, so post-state is
 *      indistinguishable from a fresh deposit of the same shares.
 */
contract YieldBasisLegacyMigrationFacet {
    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IERC20 public immutable _lpToken;
    address public immutable _underlying;

    constructor(address portfolioFactory, address gauge, address lendingPool) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        require(lendingPool != address(0), "Invalid lending pool");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IERC20(IYieldBasisGauge(gauge).asset());
        _underlying = ILendingPool(lendingPool).lendingAsset();
    }

    function _config() internal view returns (address) {
        return address(_portfolioFactory.portfolioFactoryConfig());
    }

    function migrateYieldBasisCollateral() external {
        require(
            DynamicYieldBasisCollateralManager.getCollateralShares() == 0,
            "YBLM: already migrated"
        );

        uint256 total = _lpToken.balanceOf(address(this));
        uint256 gaugeShares = IERC20(address(_gauge)).balanceOf(address(this));
        if (gaugeShares > 0) {
            total += _gauge.convertToAssets(gaugeShares);
        }

        DynamicYieldBasisCollateralManager.addCollateral(
            _config(),
            address(_lpToken),
            address(_gauge),
            _underlying,
            total
        );
    }
}
