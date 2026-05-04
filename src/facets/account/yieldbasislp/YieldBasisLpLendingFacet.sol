// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {YieldBasisCollateralManager} from "./YieldBasisCollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";

/**
 * @title YieldBasisLpLendingFacet
 * @dev Lending facet for borrowing against YieldBasis LP gauge shares.
 *      Uses underlying-denominated collateral values (via LP pricePerShare)
 *      for accurate maxLoan calculations.
 */
contract YieldBasisLpLendingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IERC20 public immutable _lendingToken;
    address public immutable _gauge;
    address public immutable _lpToken;
    address public immutable _underlying;

    event Borrowed(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner);
    event Paid(uint256 amount, address indexed owner);

    /// @dev `_lendingToken` and `_underlying` are both derived from
    ///      `lendingPool.lendingAsset()` so they are equal by construction —
    ///      eliminating the operator-error surface where a deploy could pass
    ///      mismatched values.
    constructor(address portfolioFactory, address lendingPool, address gauge) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(lendingPool != address(0), "Invalid lending pool");
        require(gauge != address(0), "Invalid gauge");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        address asset = ILendingPool(lendingPool).lendingAsset();
        _lendingToken = IERC20(asset);
        _gauge = gauge;
        _lpToken = IYieldBasisGauge(gauge).asset();
        _underlying = asset;
    }

    function _config() internal view returns (address) {
        return address(_portfolioFactory.portfolioFactoryConfig());
    }

    /**
     * @dev Borrow against YB LP collateral (underlying-denominated)
     */
    function borrow(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = _config();
        SequencerLivenessLib.assertUp(config);
        (uint256 amountAfterFees, uint256 originationFee) = YieldBasisCollateralManager.increaseTotalDebt(
            config, _lpToken, _underlying, amount
        );

        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);

        emit Borrowed(amount, amountAfterFees, originationFee, portfolioOwner);
    }

    /**
     * @dev Pay back debt
     */
    function pay(uint256 amount) external returns (uint256 excess) {
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        _lendingToken.safeTransferFrom(from, address(this), amount);

        uint256 excess = YieldBasisCollateralManager.decreaseTotalDebt(_config(), _lpToken, _underlying, amount);

        emit Paid(amount - excess, from);

        if (excess > 0) {
            _lendingToken.safeTransfer(from, excess);
        }

        return excess;
    }

    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return YieldBasisCollateralManager.getMaxLoan(_config(), _lpToken, _underlying);
    }

    function getTotalDebt() external view returns (uint256) {
        return YieldBasisCollateralManager.getTotalDebt();
    }
}
