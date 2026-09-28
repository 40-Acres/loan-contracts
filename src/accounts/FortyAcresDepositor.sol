// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFortyAcresDepositor} from "./IFortyAcresDepositor.sol";
import {IPortfolioManager} from "./IPortfolioManager.sol";
import {IPortfolioFactory} from "./IPortfolioFactory.sol";

/**
 * @title FortyAcresDepositor
 * @notice One fixed, verified contract per chain that is the ONLY address a
 *         user ever approves to deposit into 40 Acres.
 *
 * @dev Why. Portfolio accounts are CREATE2 diamonds created lazily inside the
 *      user's first `PortfolioManager.multicall`. Asking a user to approve a
 *      predicted account that has no code yet makes every wallet risk engine
 *      flag the spender as an EOA / potential scam, and a per-user account can
 *      never build reputation. This contract is the stable spender instead.
 *
 *      What it does. `deposit721` / `deposit20` move the caller's own asset into
 *      the caller's own portfolio at a factory registered with one of the
 *      PortfolioManagers fixed at construction, creating the portfolio first
 *      when it does not exist yet. Nothing in the core changes: the portfolio
 *      receives the asset exactly as it would from the user's wallet. For
 *      veNFT platforms the account's `onERC721Received` registers the token as
 *      collateral on receipt, so a deposit is a single transaction after the
 *      one-time approval. Assets that need an explicit facet call afterwards
 *      (e.g. ERC4626 `addCollateral(shares)`) are added through the usual
 *      multicall, which already accepts balances sitting in the account.
 *
 *      Trust surface. No owner, no upgrade, no allowlist edits: the manager set
 *      is immutable. `from` is always msg.sender and the destination is always
 *      msg.sender's own portfolio, so an approval to this contract can only ever
 *      move the approver's assets into the approver's account. It never holds
 *      a balance.
 *
 *      Users approve once: `setApprovalForAll(depositor, true)` for a veNFT
 *      collection (or `approve(depositor, tokenId)` per token), and
 *      `approve(depositor, amount)` per ERC20.
 */
contract FortyAcresDepositor is IFortyAcresDepositor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Set once in the constructor, never modified.
    address[] private _managers;

    constructor(address[] memory managers) {
        if (managers.length == 0) revert NoManagers();
        for (uint256 i = 0; i < managers.length; i++) {
            if (managers[i] == address(0)) revert ZeroAddress();
            _managers.push(managers[i]);
        }
    }

    // ──────────────────────────────────────────────
    // Deposits
    // ──────────────────────────────────────────────

    /// @inheritdoc IFortyAcresDepositor
    function deposit721(address factory, address token, uint256 tokenId)
        external
        nonReentrant
        returns (address portfolio)
    {
        portfolio = _ensurePortfolio(factory, msg.sender);
        IERC721(token).safeTransferFrom(msg.sender, portfolio, tokenId);
        emit Deposited721(factory, portfolio, msg.sender, token, tokenId);
    }

    /// @inheritdoc IFortyAcresDepositor
    function deposit20(address factory, address token, uint256 amount)
        external
        nonReentrant
        returns (address portfolio)
    {
        portfolio = _ensurePortfolio(factory, msg.sender);
        IERC20(token).safeTransferFrom(msg.sender, portfolio, amount);
        emit Deposited20(factory, portfolio, msg.sender, token, amount);
    }

    /**
     * @dev Resolves (or creates) `user`'s portfolio at `factory`. The factory
     *      must be registered with one of the fixed managers; `createAccount`
     *      is permissionless on the factory and registers the new account with
     *      its manager itself.
     */
    function _ensurePortfolio(address factory, address user) internal returns (address portfolio) {
        if (!_isRegisteredFactory(factory)) revert FactoryNotRegistered(factory);
        portfolio = IPortfolioFactory(factory).portfolioOf(user);
        if (portfolio == address(0)) {
            portfolio = IPortfolioFactory(factory).createAccount(user);
        }
    }

    function _isRegisteredFactory(address factory) internal view returns (bool) {
        uint256 len = _managers.length;
        for (uint256 i = 0; i < len; i++) {
            if (IPortfolioManager(_managers[i]).isRegisteredFactory(factory)) return true;
        }
        return false;
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc IFortyAcresDepositor
    function getManagers() external view returns (address[] memory) {
        return _managers;
    }

    /// @inheritdoc IFortyAcresDepositor
    function isRegisteredFactory(address factory) external view returns (bool) {
        return _isRegisteredFactory(factory);
    }

    /// @inheritdoc IFortyAcresDepositor
    function portfolioOf(address factory, address user) external view returns (address) {
        return IPortfolioFactory(factory).portfolioOf(user);
    }

    /// @inheritdoc IFortyAcresDepositor
    function isApproved721(address token, address owner, uint256 tokenId) external view returns (bool) {
        // Defensive: a collection missing one of the two views counts as "not approved".
        try IERC721(token).isApprovedForAll(owner, address(this)) returns (bool all) {
            if (all) return true;
        } catch {}
        try IERC721(token).getApproved(tokenId) returns (address approved) {
            return approved == address(this);
        } catch {}
        return false;
    }

    /// @inheritdoc IFortyAcresDepositor
    function allowance20(address token, address owner) external view returns (uint256) {
        return IERC20(token).allowance(owner, address(this));
    }
}
