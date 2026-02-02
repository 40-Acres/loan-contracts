// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IYieldBasisVotingEscrow} from "../../../interfaces/IYieldBasisVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {YieldBasisVotingEscrowAdapter} from "../../../adapters/YieldBasisVotingEscrowAdapter.sol";
import {YieldBasisFaucet} from "../../../faucets/YieldBasisFaucet.sol";

/**
 * @title YieldBasisFacet
 * @dev Facet for managing veYB lock positions on YieldBasis (Ethereum)
 *
 * All locks use INFINITE LOCK mode via infinite_lock_toggle().
 * This ensures locks never expire and maintain full voting power.
 *
 * Uses YieldBasisVotingEscrowAdapter to make veYB compatible with CollateralManager
 * which expects Aerodrome's tokenId-based IVotingEscrow interface.
 *
 * Contract Addresses (Ethereum Mainnet):
 * - YB Token: 0x01791F726B4103694969820be083196cC7c045fF
 * - veYB: 0x8235c179E9e84688FBd8B12295EfC26834dAC211
 */
contract YieldBasisFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IYieldBasisVotingEscrow public immutable _veYB;
    IERC20 public immutable _yb;
    /// @notice Adapter that makes veYB compatible with CollateralManager's IVotingEscrow interface
    YieldBasisVotingEscrowAdapter public immutable _veYBAdapter;
    /// @notice Faucet that provides YB tokens for bootstrapping locks
    YieldBasisFaucet public immutable _faucet;

    uint256 public constant MAX_LOCK_TIME = 4 * 365 days;
    uint256 public constant WEEK = 7 days;

    error LockAlreadyExists();
    error NoExistingLock();
    error ZeroAmount();
    error AlreadyInfiniteLock();

    constructor(
        address portfolioFactory,
        address portfolioAccountConfig,
        address veYB,
        address yb,
        address veYBAdapter,
        address faucet
    ) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(portfolioAccountConfig != address(0), "Invalid config");
        require(veYB != address(0), "Invalid veYB");
        require(yb != address(0), "Invalid yb");
        require(veYBAdapter != address(0), "Invalid veYB adapter");
        require(faucet != address(0), "Invalid faucet");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _veYB = IYieldBasisVotingEscrow(veYB);
        _yb = IERC20(yb);
        _veYBAdapter = YieldBasisVotingEscrowAdapter(veYBAdapter);
        _faucet = YieldBasisFaucet(faucet);
    }

    /**
     * @notice Create a new infinitely-locked veYB position
     * @param amount Amount of YB to lock
     */
    function createLock(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // Check no existing lock
        IYieldBasisVotingEscrow.LockedBalance memory existing = _veYB.locked(address(this));
        if (existing.amount > 0) revert LockAlreadyExists();

        // Calculate max lock time (rounded to week) - required for create_lock
        uint256 unlockTime = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;

        // Transfer YB from caller
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        _yb.safeTransferFrom(from, address(this), amount);
        _yb.approve(address(_veYB), amount);

        // Create lock with max time
        _veYB.create_lock(amount, unlockTime);

        // Enable infinite lock - lock never expires
        _veYB.infinite_lock_toggle();

        // Get the token ID that was created
        uint256 tokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);
        // Use adapter address so CollateralManager can call locked(tokenId) correctly
        CollateralManager.addLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_veYBAdapter));
    }

    /**
     * @notice Enable infinite lock on an existing position
     * @dev For migrating portfolios created before infinite lock was default.
     *      Infinite lock ensures the position never expires and can be transferred.
     */
    function enableInfiniteLock() external {
        IYieldBasisVotingEscrow.LockedBalance memory existing = _veYB.locked(address(this));
        if (existing.amount == 0) revert NoExistingLock();
        // Infinite lock is indicated by lock.end == type(uint256).max
        if (existing.end == type(uint256).max) revert AlreadyInfiniteLock();

        _veYB.infinite_lock_toggle();
    }

    /**
     * @notice Increase the locked YB amount
     * @dev Lock is already infinite, so just increase the amount
     * @param amount Additional YB to lock
     */
    function increaseLock(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // Verify existing lock
        IYieldBasisVotingEscrow.LockedBalance memory existing = _veYB.locked(address(this));
        if (existing.amount == 0) revert NoExistingLock();

        // Transfer YB from caller
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        _yb.safeTransferFrom(from, address(this), amount);
        _yb.approve(address(_veYB), amount);

        // Increase amount (lock is already infinite)
        _veYB.increase_amount(amount);

        uint256 tokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);
        // Use adapter address so CollateralManager can call locked(tokenId) correctly
        CollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_veYBAdapter));
    }

    /**
     * @notice Deposit an existing veYB position into the portfolio account
     * @dev If the portfolio account doesn't have an existing lock, the faucet is used
     *      to bootstrap a minimal lock first. When transferred, the incoming position
     *      merges with the existing lock and the incoming tokenId is burned.
     *
     *      IMPORTANT: The faucet is a convenience feature only. If the faucet is drained,
     *      rate limited, or unavailable, this function will fail. In that case, users should
     *      call createLock() with their own YB tokens first to establish a lock, then call
     *      depositLock() to merge additional positions.
     *
     * @param tokenId The veYB token ID to deposit (will be burned after merge)
     */
    function depositLock(uint256 tokenId) external {
        IYieldBasisVotingEscrow.LockedBalance memory existing = _veYB.locked(address(this));

        // If no existing lock, bootstrap one using the faucet
        if (existing.amount == 0) {
            _bootstrapLockFromFaucet();
        }

        // Get the portfolio's existing tokenId before the merge
        uint256 existingTokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);

        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;

        // Transfer merges positions - incoming tokenId is burned
        _veYB.safeTransferFrom(from, address(this), tokenId);

        // Update collateral using the existing tokenId (incoming was burned)
        CollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), existingTokenId, address(_veYBAdapter));
    }

    /**
     * @notice Bootstrap a minimal lock using the faucet
     * @dev Requests YB from the faucet and creates an infinitely-locked position
     */
    function _bootstrapLockFromFaucet() internal {
        // Request YB from faucet
        uint256 amount = _faucet.requestYB();
        if (amount == 0) return;

        // Calculate max lock time (rounded to week) - required for create_lock
        uint256 unlockTime = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;

        // Approve and create lock
        _yb.approve(address(_veYB), amount);
        _veYB.create_lock(amount, unlockTime);

        // Enable infinite lock
        _veYB.infinite_lock_toggle();

        // Register the collateral
        uint256 newTokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);
        CollateralManager.addLockedCollateral(address(_portfolioAccountConfig), newTokenId, address(_veYBAdapter));
    }
}
