// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IYieldBasisVotingEscrow} from "../../../interfaces/IYieldBasisVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {YieldBasisVotingEscrowAdapter} from "../../../adapters/YieldBasisVotingEscrowAdapter.sol";
import {YieldBasisFaucet} from "../../../faucets/YieldBasisFaucet.sol";

/**
 * @title DynamicYieldBasisFacet
 * @dev YieldBasisFacet variant that uses DynamicCollateralManager for storage.
 */
contract DynamicYieldBasisFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IYieldBasisVotingEscrow public immutable _veYB;
    IERC20 public immutable _yb;
    YieldBasisVotingEscrowAdapter public immutable _veYBAdapter;
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

    function createLock(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        IYieldBasisVotingEscrow.LockedBalance memory existing = _veYB.locked(address(this));
        if (existing.amount > 0) revert LockAlreadyExists();

        uint256 unlockTime = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;

        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        _yb.safeTransferFrom(from, address(this), amount);
        _yb.approve(address(_veYB), amount);

        _veYB.create_lock(amount, unlockTime);
        _veYB.infinite_lock_toggle();

        uint256 tokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);
        DynamicCollateralManager.addLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_veYBAdapter));
    }

    function increaseLock(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        IYieldBasisVotingEscrow.LockedBalance memory existing = _veYB.locked(address(this));
        if (existing.amount == 0) revert NoExistingLock();

        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        _yb.safeTransferFrom(from, address(this), amount);
        _yb.approve(address(_veYB), amount);

        _veYB.increase_amount(amount);

        uint256 tokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);
        DynamicCollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_veYBAdapter));
    }

    function depositLock(uint256 tokenId) external {
        IYieldBasisVotingEscrow.LockedBalance memory existing = _veYB.locked(address(this));

        if (existing.amount == 0) {
            _bootstrapLockFromFaucet();
        }

        uint256 existingTokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);

        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;

        _veYB.safeTransferFrom(from, address(this), tokenId);

        DynamicCollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), existingTokenId, address(_veYBAdapter));
    }

    function _bootstrapLockFromFaucet() internal {
        uint256 amount = _faucet.requestYB();
        if (amount == 0) return;

        uint256 unlockTime = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;

        _yb.approve(address(_veYB), amount);
        _veYB.create_lock(amount, unlockTime);

        _veYB.infinite_lock_toggle();

        uint256 newTokenId = _veYB.tokenOfOwnerByIndex(address(this), 0);
        DynamicCollateralManager.addLockedCollateral(address(_portfolioAccountConfig), newTokenId, address(_veYBAdapter));
    }
}
