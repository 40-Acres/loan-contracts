// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IVotingEscrow} from "../../src/interfaces/IVotingEscrow.sol";

/**
 * @title MockVotingEscrow
 * @dev Minimal veNFT mock implementing IVotingEscrow for local testing.
 *      Supports ERC721 ownership/transfers, LockedBalance tracking,
 *      createLock, increaseAmount, merge, lockPermanent, voting/abstain.
 */
contract MockVotingEscrow {
    // ── State ──────────────────────────────────────────────────────────
    address public token; // underlying ERC20 (AERO)
    uint256 private _nextTokenId = 1;

    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _approvals;
    mapping(uint256 => IVotingEscrow.LockedBalance) private _locked;
    mapping(uint256 => bool) private _voted;

    // Minimal ERC721 balance tracking
    mapping(address => uint256) private _balances;

    // ── Constructor ────────────────────────────────────────────────────
    constructor(address _token) {
        token = _token;
    }

    // ── ERC721 core ────────────────────────────────────────────────────

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "NonExistentToken");
        return owner;
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        require(msg.sender == owner || isApprovedOrOwner(msg.sender, tokenId), "NotApprovedOrOwner");
        _approvals[tokenId] = to;
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) public view returns (bool) {
        address owner = _owners[tokenId];
        return (spender == owner || _approvals[tokenId] == spender);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(isApprovedOrOwner(msg.sender, tokenId), "NotApprovedOrOwner");
        require(_owners[tokenId] == from, "TransferFromIncorrectOwner");
        require(to != address(0), "ZeroAddress");
        require(!_voted[tokenId], "AlreadyVoted");

        _approvals[tokenId] = address(0);
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        // Transfer ownership BEFORE callback (CollateralManager reads ownerOf in onERC721Received)
        transferFrom(from, to, tokenId);

        // ERC721 receiver check
        if (_isContract(to)) {
            bytes4 retval = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
            require(retval == IERC721Receiver.onERC721Received.selector, "ERC721ReceiverRejectedTokens");
        }
    }

    // ── VE functions ───────────────────────────────────────────────────

    function locked(uint256 tokenId) external view returns (IVotingEscrow.LockedBalance memory) {
        return _locked[tokenId];
    }

    function locked__end(uint256 tokenId) external view returns (uint256) {
        return _locked[tokenId].end;
    }

    function balanceOfNFT(uint256 tokenId) external view returns (uint256) {
        int128 amount = _locked[tokenId].amount;
        if (amount <= 0) return 0;
        return uint256(uint128(amount));
    }

    function balanceOfNFTAt(uint256 tokenId, uint256) external view returns (uint256) {
        int128 amount = _locked[tokenId].amount;
        if (amount <= 0) return 0;
        return uint256(uint128(amount));
    }

    function createLock(uint256 value, uint256 lockDuration) external returns (uint256 tokenId) {
        require(value > 0, "ZeroAmount");
        IERC20(token).transferFrom(msg.sender, address(this), value);

        tokenId = _nextTokenId++;
        _owners[tokenId] = msg.sender;
        _balances[msg.sender] += 1;
        _locked[tokenId] = IVotingEscrow.LockedBalance({
            amount: int128(uint128(value)),
            end: block.timestamp + lockDuration,
            isPermanent: false
        });
    }

    function create_lock_for(uint256 value, uint256 lockDuration, address to) external returns (uint256 tokenId) {
        require(value > 0, "ZeroAmount");
        IERC20(token).transferFrom(msg.sender, address(this), value);

        tokenId = _nextTokenId++;
        _owners[tokenId] = to;
        _balances[to] += 1;
        _locked[tokenId] = IVotingEscrow.LockedBalance({
            amount: int128(uint128(value)),
            end: block.timestamp + lockDuration,
            isPermanent: false
        });
    }

    function increaseAmount(uint256 tokenId, uint256 value) external {
        require(value > 0, "ZeroAmount");
        require(_owners[tokenId] != address(0), "NonExistentToken");
        IERC20(token).transferFrom(msg.sender, address(this), value);
        _locked[tokenId].amount += int128(uint128(value));
    }

    function merge(uint256 from, uint256 to) external {
        require(_owners[from] != address(0), "NonExistentToken");
        require(_owners[to] != address(0), "NonExistentToken");
        require(from != to, "SameNFT");
        require(isApprovedOrOwner(msg.sender, from), "NotApprovedOrOwner");

        int128 fromAmount = _locked[from].amount;
        _locked[to].amount += fromAmount;

        // Burn the `from` token
        address fromOwner = _owners[from];
        _locked[from] = IVotingEscrow.LockedBalance(0, 0, false);
        _balances[fromOwner] -= 1;
        _owners[from] = address(0);
    }

    function lockPermanent(uint256 tokenId) external {
        require(_owners[tokenId] != address(0), "NonExistentToken");
        _locked[tokenId].isPermanent = true;
        _locked[tokenId].end = 0; // permanent locks have no end
    }

    function voting(uint256 tokenId) external {
        _voted[tokenId] = true;
    }

    function abstain(uint256 tokenId) external {
        _voted[tokenId] = false;
    }

    function voted(uint256 tokenId) external view returns (bool) {
        return _voted[tokenId];
    }

    function deposit_for(uint256 tokenId, uint256 value) external {
        require(_owners[tokenId] != address(0), "NonExistentToken");
        IERC20(token).transferFrom(msg.sender, address(this), value);
        _locked[tokenId].amount += int128(uint128(value));
    }

    function reset(uint256 tokenId) external {
        _voted[tokenId] = false;
    }

    // Stubs for interface completeness
    function checkpoint() external {}
    function attach(uint256) external {}
    function detach(uint256) external {}
    function totalSupply() external pure returns (uint256) { return 0; }
    function epoch() external pure returns (uint256) { return 0; }
    function team() external pure returns (address) { return address(0); }
    function point_history(uint256) external pure returns (IVotingEscrow.Point memory) {
        return IVotingEscrow.Point(0, 0, 0, 0);
    }
    function user_point_history(uint256, uint256) external pure returns (IVotingEscrow.Point memory) {
        return IVotingEscrow.Point(0, 0, 0, 0);
    }
    function user_point_epoch(uint256) external pure returns (uint256) { return 0; }

    // ── Test helpers ───────────────────────────────────────────────────

    /// @dev Mint a veNFT to `to` with given locked amount, without pulling tokens.
    ///      Useful for test setup where you don't want to deal with token approvals.
    function mintTo(address to, int128 amount) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _owners[tokenId] = to;
        _balances[to] += 1;
        _locked[tokenId] = IVotingEscrow.LockedBalance({
            amount: amount,
            end: 0,
            isPermanent: true
        });
    }

    // ── Internal ───────────────────────────────────────────────────────

    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }
}
