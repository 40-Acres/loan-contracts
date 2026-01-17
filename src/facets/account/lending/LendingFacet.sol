// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {UserLendingConfig} from "./UserLendingConfig.sol";
import {CollateralFacet} from "../collateral/CollateralFacet.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
/**
 * @title LendingFacet
 * @dev Facet for borrowing against collateral in portfolio accounts.
 *      Global debt tracked via CollateralManager, per-loan details from loan contract.
 */
contract LendingFacet is AccessControl {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IERC20 public immutable _lendingToken;

    error NotOwnerOfToken();
    error NotPortfolioOwner();

    constructor(address portfolioFactory, address portfolioAccountConfig, address lendingToken) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _lendingToken = IERC20(lendingToken);
    }

    function borrow(uint256 amount) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        uint256 minimumCollateral = _portfolioAccountConfig.getMinimumCollateral();
        if(minimumCollateral > 0) {
            require(ICollateralFacet(address(this)).getTotalLockedCollateral() >= minimumCollateral, "Minimum collateral not met");
        }
        uint256 amountAfterFees = CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), amount);
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);
    }

    /**
     * @dev Borrow funds to a specific address within the 40acres ecosystem
     * @param to The address to borrow funds to
     * @param amount The amount of funds to borrow
     * @notice Borrow funds to a specific address within the 40acres ecosystem
     */
    function borrowTo(address to, uint256 amount) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        PortfolioManager manager = PortfolioManager(address(_portfolioFactory.portfolioManager()));
        // 1. Verify existence and get the specific factory for the 'to' portfolio
        require(manager.isPortfolioRegistered(to), "To address is not part of 40acres");
        address toFactoryAddress = manager.getFactoryForPortfolio(to);

        // 2. Get the owner from the correct factory
        address portfolioOwner = PortfolioFactory(toFactoryAddress).ownerOf(to);

        // 3. Verify ownership matches the current portfolio's owner
        require(portfolioOwner == _portfolioFactory.ownerOf(address(this)), "not the same owner for to address and current portfolio");


        uint256 amountAfterFees = CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), amount);
        _lendingToken.safeTransfer(to, amountAfterFees);
    }

    function pay(uint256 amount) public {
        // if the caller is the portfolio manager, use the portfolio owner as the from address, otherwise use the caller
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;

        // transfer the funds from the from address to the portfolio account then pay the loan
        _lendingToken.safeTransferFrom(from, address(this), amount);
        IERC20(address(_lendingToken)).approve(address(_portfolioAccountConfig.getLoanContract()), amount);
        uint256 excess = CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), amount);
        IERC20(address(_lendingToken)).approve(address(_portfolioAccountConfig.getLoanContract()), 0);
        // refund excess to the from address
        if(excess > 0) {
            _lendingToken.safeTransfer(from, excess);
        }
    }

    function setTopUp(bool topUpEnabled) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserLendingConfig.setTopUp(topUpEnabled);
    }

    function topUp() public {
        bool topUpEnabled = UserLendingConfig.getTopUp();
        if(!topUpEnabled) {
            return;
        }
        (uint256 maxLoan, ) = CollateralFacet(address(this)).getMaxLoan();
        if(maxLoan == 0) {
            return;
        }
        uint256 amountAfterFees = CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), maxLoan);
        // send to portfolio owner
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);
    }
}