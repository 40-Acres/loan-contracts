// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";

/**
 * @title AccessControl
 * @dev Library for access control
 */
abstract contract AccessControl {
    error NotPortfolioManagerMulticall();
    error NotAuthorizedCaller();

    modifier onlyPortfolioManagerMulticall(PortfolioFactory portfolioFactory) {
        require(msg.sender == address(portfolioFactory.portfolioManager()), NotPortfolioManagerMulticall());
        _;
    }

    modifier onlyAuthorizedCaller(PortfolioFactory portfolioFactory) {
        require(portfolioFactory.portfolioManager().isAuthorizedCaller(msg.sender), NotAuthorizedCaller());
        _;
    }
}