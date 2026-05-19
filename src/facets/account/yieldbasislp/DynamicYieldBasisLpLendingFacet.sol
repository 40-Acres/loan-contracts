// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {DynamicYieldBasisCollateralManager} from "./DynamicYieldBasisCollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";
import {UserLendingConfig} from "../lending/UserLendingConfig.sol";

/**
 * @title DynamicYieldBasisLpLendingFacet
 * @dev Borrow/repay against YB LP gauge collateral, talking to a vault that
 *      may mutate debt mid-call (reward streaming, vesting settlement).
 *
 *      Adds reentrancy guards on borrow/pay/topUp using a slot shared with
 *      the claiming facet: harvest is debt-aware and must not interleave with
 *      borrow/repay flows on the same diamond.
 */
contract DynamicYieldBasisLpLendingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IERC20 public immutable _lendingToken;
    address public immutable _gauge;
    address public immutable _lpToken;
    address public immutable _underlying;

    error ReentrantCall();

    bytes32 private constant _LENDING_REENTRANCY_SLOT = keccak256("fortyacres.lending.reentrancy");

    modifier nonReentrant() {
        bytes32 slot = _LENDING_REENTRANCY_SLOT;
        uint256 status;
        assembly { status := sload(slot) }
        if (status == 2) revert ReentrantCall();
        assembly { sstore(slot, 2) }
        _;
        assembly { sstore(slot, 1) }
    }

    event Borrowed(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner);
    event Paid(uint256 amount, address indexed owner);
    event TopUpSet(bool topUpEnabled, address indexed owner);
    event ToppedUp(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner);

    /// @dev `_lendingToken` and `_underlying` are both derived from
    ///      `lendingPool.lendingAsset()` so they are equal by construction.
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

    function borrow(uint256 amount) external nonReentrant onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = _config();
        SequencerLivenessLib.assertUp(config);
        (uint256 amountAfterFees, uint256 originationFee) = DynamicYieldBasisCollateralManager.increaseTotalDebt(
            config, _lpToken, _underlying, amount
        );

        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);

        emit Borrowed(amount, amountAfterFees, originationFee, portfolioOwner);
    }

    function pay(uint256 amount) external nonReentrant returns (uint256 excess) {
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        _lendingToken.safeTransferFrom(from, address(this), amount);

        excess = DynamicYieldBasisCollateralManager.decreaseTotalDebt(_config(), _lpToken, _underlying, amount);

        emit Paid(amount - excess, from);

        if (excess > 0) {
            _lendingToken.safeTransfer(from, excess);
        }

        return excess;
    }

    function setTopUp(bool topUpEnabled) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserLendingConfig.setTopUp(topUpEnabled);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit TopUpSet(topUpEnabled, owner);
    }

    function topUp() external nonReentrant onlyAuthorizedCaller(_portfolioFactory) {
        if (!UserLendingConfig.getTopUp()) return;

        address config = _config();
        SequencerLivenessLib.assertUp(config);

        (uint256 maxLoan, ) = DynamicYieldBasisCollateralManager.getMaxLoan(config, _lpToken, _underlying);
        if (maxLoan == 0) return;

        (uint256 amountAfterFees, uint256 originationFee) =
            DynamicYieldBasisCollateralManager.increaseTotalDebt(config, _lpToken, _underlying, maxLoan);

        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);

        emit ToppedUp(maxLoan, amountAfterFees, originationFee, portfolioOwner);
    }

    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return DynamicYieldBasisCollateralManager.getMaxLoan(_config(), _lpToken, _underlying);
    }

    function getTotalDebt() external view returns (uint256) {
        return DynamicYieldBasisCollateralManager.getTotalDebt(_config());
    }
}
