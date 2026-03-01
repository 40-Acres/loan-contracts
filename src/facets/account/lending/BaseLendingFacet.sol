// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IPortfolioFactory} from "../../../accounts/IPortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {UserLendingConfig} from "./UserLendingConfig.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";

/**
 * @title BaseLendingFacet
 * @dev Abstract base for LendingFacet and DynamicLendingFacet.
 *      Concrete subclasses implement the internal dispatchers to route
 *      to either CollateralManager or DynamicCollateralManager.
 */
abstract contract BaseLendingFacet is AccessControl {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IERC20 public immutable _lendingToken;

    error NotOwnerOfToken();
    error NotPortfolioOwner();
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
    event BorrowedTo(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner, address indexed to);
    event Paid(uint256 amount, address indexed owner);
    event TopUpSet(bool topUpEnabled, address indexed owner);
    event ToppedUp(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner);

    constructor(address portfolioFactory, address portfolioAccountConfig, address lendingToken) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _lendingToken = IERC20(lendingToken);
    }

    // ──────────────────────────────────────────────
    // Abstract internal dispatchers
    // ──────────────────────────────────────────────

    function _increaseTotalDebt(address config, uint256 amount) internal virtual returns (uint256 amountAfterFees, uint256 originationFee);
    function _decreaseTotalDebt(address config, uint256 amount) internal virtual returns (uint256 excess);
    function _enforceCollateralRequirements() internal virtual view;

    // ──────────────────────────────────────────────
    // Public functions
    // ──────────────────────────────────────────────

    function borrow(uint256 amount) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        uint256 minimumCollateral = _portfolioAccountConfig.getMinimumCollateral();
        if(minimumCollateral > 0) {
            require(ICollateralFacet(address(this)).getTotalLockedCollateral() >= minimumCollateral, "Minimum collateral not met");
        }
        (uint256 amountAfterFees, uint256 originationFee) = _increaseTotalDebt(address(_portfolioAccountConfig), amount);
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);
        emit Borrowed(amount, amountAfterFees, originationFee, portfolioOwner);
    }

    /**
     * @dev Borrow funds to the caller's portfolio on a different factory
     * @param toFactory The PortfolioFactory where the destination portfolio lives
     * @param amount The amount of funds to borrow
     */
    function borrowTo(IPortfolioFactory toFactory, uint256 amount) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        PortfolioManager manager = PortfolioManager(address(_portfolioFactory.portfolioManager()));
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        address toPortfolio = toFactory.portfolioOf(portfolioOwner);
        require(toPortfolio != address(0), "No portfolio on target factory");
        require(manager.isPortfolioRegistered(toPortfolio), "Target portfolio not registered");

        (uint256 amountAfterFees, uint256 originationFee) = _increaseTotalDebt(address(_portfolioAccountConfig), amount);
        _lendingToken.safeTransfer(toPortfolio, amountAfterFees);
        emit BorrowedTo(amount, amountAfterFees, originationFee, portfolioOwner, toPortfolio);
    }

    function pay(uint256 amount) public nonReentrant returns (uint256) {
        // if the caller is the portfolio manager, use the portfolio owner as the from address, otherwise use the caller
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;

        // transfer the funds from the from address to the portfolio account then pay the loan
        _lendingToken.safeTransferFrom(from, address(this), amount);
        uint256 excess = _decreaseTotalDebt(address(_portfolioAccountConfig), amount);

        emit Paid(amount-excess, from);
        // refund excess to the from address
        if(excess > 0) {
            _lendingToken.safeTransfer(from, excess);
        }
        return excess;
    }

    function setTopUp(bool topUpEnabled) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserLendingConfig.setTopUp(topUpEnabled);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit TopUpSet(topUpEnabled, owner);
    }

    function topUp() public {
        bool topUpEnabled = UserLendingConfig.getTopUp();
        if(!topUpEnabled) {
            return;
        }
        (uint256 maxLoan, ) = ICollateralFacet(address(this)).getMaxLoan();
        if(maxLoan == 0) {
            return;
        }
        (uint256 amountAfterFees, uint256 originationFee) = _increaseTotalDebt(address(_portfolioAccountConfig), maxLoan);
        // send to portfolio owner
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);
        _enforceCollateralRequirements();
        emit ToppedUp(maxLoan, amountAfterFees, originationFee, portfolioOwner);
    }

    function getMaxLoan() public view returns (uint256, uint256) {
        return ICollateralFacet(address(this)).getMaxLoan();
    }

    function getPortfolioAccountConfig() public view returns (PortfolioAccountConfig) {
        return _portfolioAccountConfig;
    }

    function getLendingToken() public view returns (IERC20) {
        return _lendingToken;
    }
}
