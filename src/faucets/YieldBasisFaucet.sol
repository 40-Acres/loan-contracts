// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioManager} from "../accounts/PortfolioManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title YieldBasisFaucet
 * @dev Dispenses small amounts of YB tokens to portfolio accounts to bootstrap locks.
 *
 * When a user wants to deposit an existing veYB position but their portfolio account
 * doesn't have an existing lock (required by veYB for transfers), this faucet provides
 * a small amount of YB to create an initial lock.
 *
 * IMPORTANT: This faucet is a CONVENIENCE feature only. If the faucet is drained or
 * rate limited, users can still use the protocol by calling createLock() with their
 * own YB tokens before depositing veYB positions.
 *
 * Abuse Prevention:
 * - Each portfolio can only receive once (hasReceived mapping)
 * - Global rate limiting: maximum dispensations per time window
 * - Only valid portfolios registered with PortfolioManager can request
 */
contract YieldBasisFaucet is Ownable2Step {
    using SafeERC20 for IERC20;

    PortfolioManager public immutable portfolioManager;
    IERC20 public immutable yb;

    /// @notice Amount of YB dispensed per request
    uint256 public dispenseAmount;

    /// @notice Track which portfolios have already received from faucet
    mapping(address => bool) public hasReceived;

    /// @notice Rate limiting: max dispensations per window
    uint256 public maxDispensesPerWindow;
    /// @notice Rate limiting: window duration in seconds
    uint256 public windowDuration;
    /// @notice Rate limiting: current window start timestamp
    uint256 public currentWindowStart;
    /// @notice Rate limiting: dispensations in current window
    uint256 public dispensesInCurrentWindow;

    event Dispensed(address indexed portfolio, uint256 amount);
    event DispenseAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event RateLimitUpdated(uint256 maxDispensesPerWindow, uint256 windowDuration);
    event FaucetFunded(address indexed funder, uint256 amount);
    event FaucetDrained(address indexed to, uint256 amount);

    constructor(
        address _portfolioManager,
        address _yb,
        uint256 _dispenseAmount,
        uint256 _maxDispensesPerWindow,
        uint256 _windowDuration
    ) Ownable(msg.sender) {
        require(_portfolioManager != address(0), "Invalid portfolio manager");
        require(_yb != address(0), "Invalid YB token");
        portfolioManager = PortfolioManager(_portfolioManager);
        yb = IERC20(_yb);
        dispenseAmount = _dispenseAmount;
        maxDispensesPerWindow = _maxDispensesPerWindow;
        windowDuration = _windowDuration;
        currentWindowStart = block.timestamp;
    }

    /**
     * @notice Request YB tokens for a portfolio account
     * @dev Only callable by valid portfolio accounts. Each portfolio can only receive once.
     *      Returns 0 if caller is not a valid portfolio, has already received, or rate limited.
     *      This is a convenience feature - if it returns 0, users should call createLock() directly.
     * @return amount The amount of YB tokens dispensed (0 if ineligible or rate limited)
     */
    function requestYB() external returns (uint256 amount) {
        // Return 0 if caller is not a valid portfolio account
        if (!_isValidPortfolio(msg.sender)) return 0;

        // Return 0 if portfolio has already received
        if (hasReceived[msg.sender]) return 0;

        // Check faucet has enough balance
        uint256 balance = yb.balanceOf(address(this));
        if (balance < dispenseAmount) return 0;

        // Rate limiting check
        if (block.timestamp >= currentWindowStart + windowDuration) {
            // Start new window
            currentWindowStart = block.timestamp;
            dispensesInCurrentWindow = 0;
        }
        if (dispensesInCurrentWindow >= maxDispensesPerWindow) return 0;

        // Mark as received and transfer
        hasReceived[msg.sender] = true;
        dispensesInCurrentWindow++;
        yb.safeTransfer(msg.sender, dispenseAmount);

        emit Dispensed(msg.sender, dispenseAmount);
        return dispenseAmount;
    }

    /**
     * @notice Check if an address is a valid portfolio account
     * @param account The address to check
     * @return True if the account is a portfolio deployed from a factory under the manager
     */
    function isValidPortfolio(address account) external view returns (bool) {
        return _isValidPortfolio(account);
    }

    /**
     * @notice Update the dispense amount
     * @param newAmount The new amount to dispense per request
     */
    function setDispenseAmount(uint256 newAmount) external onlyOwner {
        emit DispenseAmountUpdated(dispenseAmount, newAmount);
        dispenseAmount = newAmount;
    }

    /**
     * @notice Update rate limiting parameters
     * @param _maxDispensesPerWindow Maximum dispensations allowed per window
     * @param _windowDuration Duration of each rate limit window in seconds
     */
    function setRateLimit(uint256 _maxDispensesPerWindow, uint256 _windowDuration) external onlyOwner {
        maxDispensesPerWindow = _maxDispensesPerWindow;
        windowDuration = _windowDuration;
        emit RateLimitUpdated(_maxDispensesPerWindow, _windowDuration);
    }

    /**
     * @notice Fund the faucet with YB tokens
     * @param amount The amount of YB to deposit
     */
    function fund(uint256 amount) external {
        yb.safeTransferFrom(msg.sender, address(this), amount);
        emit FaucetFunded(msg.sender, amount);
    }

    /**
     * @notice Drain the faucet (owner only)
     * @param to The address to send tokens to
     * @param amount The amount to withdraw
     */
    function drain(address to, uint256 amount) external onlyOwner {
        yb.safeTransfer(to, amount);
        emit FaucetDrained(to, amount);
    }

    /**
     * @notice Reset the received status for a portfolio (owner only)
     * @param portfolio The portfolio address to reset
     */
    function resetReceived(address portfolio) external onlyOwner {
        hasReceived[portfolio] = false;
    }

    /**
     * @dev Check if an address is a valid portfolio registered with the manager
     */
    function _isValidPortfolio(address account) internal view returns (bool) {
        return portfolioManager.isPortfolioRegistered(account);
    }
}
