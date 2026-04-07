// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioManager} from "../accounts/PortfolioManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title YieldBasisFaucet
 * @dev Dispenses 1 wei of YB tokens to portfolio accounts to bootstrap locks.
 *
 * When a user wants to deposit an existing veYB position but their portfolio account
 * doesn't have an existing lock (required by veYB for transfers), this faucet provides
 * 1 wei of YB to create an initial lock. The gas cost to call this far exceeds the
 * value dispensed, making abuse uneconomical.
 *
 * Abuse Prevention:
 * - Each portfolio can only receive once (hasReceived mapping)
 * - Only valid portfolios registered with PortfolioManager can request
 * - Dispense amount is trivial (1 wei)
 */
contract YieldBasisFaucet is Ownable2Step {
    using SafeERC20 for IERC20;

    PortfolioManager public immutable portfolioManager;
    IERC20 public immutable yb;

    /// @notice Amount of YB dispensed per request
    uint256 public dispenseAmount;

    /// @notice Track which portfolios have already received from faucet
    mapping(address => bool) public hasReceived;

    event Dispensed(address indexed portfolio, uint256 amount);
    event DispenseAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event FaucetFunded(address indexed funder, uint256 amount);
    event FaucetDrained(address indexed to, uint256 amount);

    constructor(
        address _portfolioManager,
        address _yb,
        uint256 _dispenseAmount
    ) Ownable(msg.sender) {
        require(_portfolioManager != address(0), "Invalid portfolio manager");
        require(_yb != address(0), "Invalid YB token");
        portfolioManager = PortfolioManager(_portfolioManager);
        yb = IERC20(_yb);
        dispenseAmount = _dispenseAmount;
    }

    /**
     * @notice Request YB tokens for a portfolio account
     * @dev Only callable by valid portfolio accounts. Each portfolio can only receive once.
     *      Returns 0 if caller is not a valid portfolio, has already received, or faucet is empty.
     * @return amount The amount of YB tokens dispensed (0 if ineligible)
     */
    function requestYB() external returns (uint256 amount) {
        if (!_isValidPortfolio(msg.sender)) return 0;
        if (hasReceived[msg.sender]) return 0;

        uint256 balance = yb.balanceOf(address(this));
        if (balance < dispenseAmount) return 0;

        hasReceived[msg.sender] = true;
        yb.safeTransfer(msg.sender, dispenseAmount);

        emit Dispensed(msg.sender, dispenseAmount);
        return dispenseAmount;
    }

    /**
     * @notice Check if an address is a valid portfolio account
     */
    function isValidPortfolio(address account) external view returns (bool) {
        return _isValidPortfolio(account);
    }

    /**
     * @notice Update the dispense amount
     */
    function setDispenseAmount(uint256 newAmount) external onlyOwner {
        emit DispenseAmountUpdated(dispenseAmount, newAmount);
        dispenseAmount = newAmount;
    }

    /**
     * @notice Fund the faucet with YB tokens
     */
    function fund(uint256 amount) external {
        yb.safeTransferFrom(msg.sender, address(this), amount);
        emit FaucetFunded(msg.sender, amount);
    }

    /**
     * @notice Drain the faucet (owner only)
     */
    function drain(address to, uint256 amount) external onlyOwner {
        yb.safeTransfer(to, amount);
        emit FaucetDrained(to, amount);
    }

    /**
     * @notice Reset the received status for a portfolio (owner only)
     */
    function resetReceived(address portfolio) external onlyOwner {
        hasReceived[portfolio] = false;
    }

    function _isValidPortfolio(address account) internal view returns (bool) {
        return portfolioManager.isPortfolioRegistered(account);
    }
}
