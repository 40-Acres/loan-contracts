// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ITokenMessenger} from "../../src/interfaces/ITokenMessenger.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockTokenMessenger
 * @dev Mock implementation of ITokenMessenger for testing BridgeFacet
 * This mock simulates the CCTP TokenMessenger behavior by transferring tokens
 */
contract MockTokenMessenger is ITokenMessenger {
    event DepositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external override {
        // In real CCTP, this would burn the tokens
        // For testing, we'll transfer them to this contract to simulate burning
        if (amount > 0) {
            IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        }
        
        emit DepositForBurn(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold
        );
    }
}

