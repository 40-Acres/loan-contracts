// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IFlashLoanReceiver.sol";
import "../interfaces/IFlashLoanProvider.sol";

/**
 * @title FlashLoanReceiver
 * @notice Base contract for receiving flash loans from the 40 Acres protocol
 * @dev Developers should inherit from this contract and implement the executeOperation function
 */
abstract contract FlashLoanReceiver is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    // The address of the flash loan provider
    address public immutable FLASH_LOAN_PROVIDER;
    
    // The keccak256 hash required to be returned by onFlashLoan
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /**
     * @dev Constructor
     * @param provider The address of the flash loan provider
     */
    constructor(address provider) {
        FLASH_LOAN_PROVIDER = provider;
    }

    /**
     * @notice Callback function called by the flash loan provider
     * @dev Validates parameters and calls the executeOperation function which should be implemented by the inheriting contract
     * @param initiator The address that initiated the flash loan
     * @param token The address of the token being borrowed
     * @param amount The amount of tokens borrowed
     * @param fee The fee for the flash loan
     * @param data Additional data passed to the flash loan function
     * @return The keccak256 hash of "ERC3156FlashBorrower.onFlashLoan"
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        // Ensure the caller is the flash loan provider
        require(msg.sender == FLASH_LOAN_PROVIDER, "Caller is not the flash loan provider");
        
        // Execute the flash loan operation
        executeOperation(token, amount, fee, initiator, data);
        
        // Approve the repayment amount to the flash loan provider
        IERC20(token).approve(FLASH_LOAN_PROVIDER, amount + fee);
        
        return CALLBACK_SUCCESS;
    }

    /**
     * @notice Executes the logic during the flash loan
     * @dev Must be implemented by the inheriting contract
     * @param token The address of the token being borrowed
     * @param amount The amount of tokens borrowed
     * @param fee The fee for the flash loan
     * @param initiator The address that initiated the flash loan
     * @param data Additional data passed to the flash loan function
     */
    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata data
    ) internal virtual;
}