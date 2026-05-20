// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IHydrexVotingEscrow} from "../../../../src/interfaces/IHydrexVotingEscrow.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal mock of Hydrex VotingEscrow used purely to validate the
///         portfolio-account facet wiring. Mock-defined behaviour ONLY -- this
///         does not reflect real Hydrex semantics beyond what's needed to
///         exercise the receiver hook, merge, and lock-detail reads.
contract MockHydrexVotingEscrow is IHydrexVotingEscrow {
    address public immutable _token;

    mapping(uint256 => address) internal _owners;
    mapping(uint256 => LockDetails) internal _lockDetails;
    uint256 internal _nextTokenId = 1;

    // Per-owner ERC721Enumerable surface (matches OZ ERC721EnumerableUpgradeable).
    // claimRebase walks this to find rebase-minted veNFTs since Hydrex's _createLock
    // uses _mint (unsafe), so the receiver hook does not fire on the rebase path.
    mapping(address => uint256[]) internal _ownerTokens;
    mapping(uint256 => uint256) internal _ownerTokensIndex;

    // Knobs used to simulate Hydrex behaviour
    bool public increaseUnlockTimeReverts;
    bool public mintAsPermanentOnCreateLock;

    // Re-entrancy probe: when set, attempts to re-enter the recipient hook within
    // the same transfer that already fired onERC721Received.
    bool public reentryArmed;
    address public reentryTarget;
    uint256 public reentryTokenId;

    // Call-count tracking
    uint256 public increaseUnlockTimeCalls;
    uint256 public lockPermanentCalls; // expected to remain 0 with new design
    uint256 public mergeCalls;

    constructor(address underlying) {
        _token = underlying;
    }

    function token() external view override returns (address) {
        return _token;
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return _owners[tokenId];
    }

    function approve(address, uint256) external override {}

    function balanceOfNFT(uint256 tokenId) external view override returns (uint256) {
        return _lockDetails[tokenId].amount;
    }

    function balanceOfNFTAt(uint256 tokenId, uint256) external view override returns (uint256) {
        return _lockDetails[tokenId].amount;
    }

    function lockDetails(uint256 tokenId) external view override returns (LockDetails memory) {
        return _lockDetails[tokenId];
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _ownerTokens[owner].length;
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        return _ownerTokens[owner][index];
    }

    function _addToOwner(address owner, uint256 tokenId) internal {
        if (owner == address(0)) return;
        _ownerTokensIndex[tokenId] = _ownerTokens[owner].length;
        _ownerTokens[owner].push(tokenId);
    }

    function _removeFromOwner(address owner, uint256 tokenId) internal {
        if (owner == address(0)) return;
        uint256[] storage arr = _ownerTokens[owner];
        uint256 lastIndex = arr.length - 1;
        uint256 thisIndex = _ownerTokensIndex[tokenId];
        if (thisIndex != lastIndex) {
            uint256 lastTokenId = arr[lastIndex];
            arr[thisIndex] = lastTokenId;
            _ownerTokensIndex[lastTokenId] = thisIndex;
        }
        arr.pop();
        delete _ownerTokensIndex[tokenId];
    }

    function _setOwner(uint256 tokenId, address newOwner) internal {
        address prev = _owners[tokenId];
        if (prev == newOwner) return;
        _removeFromOwner(prev, tokenId);
        _owners[tokenId] = newOwner;
        _addToOwner(newOwner, tokenId);
    }

    function _safeNotify(address to, uint256 tokenId) internal {
        if (to.code.length > 0) {
            bytes4 retval = IERC721Receiver(to).onERC721Received(msg.sender, address(0), tokenId, "");
            require(retval == IERC721Receiver.onERC721Received.selector, "ERC721: invalid receiver");
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        require(_owners[tokenId] == from, "from not owner");
        _setOwner(tokenId, to);
        _safeNotify(to, tokenId);

        if (reentryArmed) {
            reentryArmed = false; // one-shot
            // Try to re-enter the recipient's onERC721Received within the same
            // transfer. The nonReentrant guard on the facet should reject this.
            IERC721Receiver(reentryTarget).onERC721Received(address(this), from, reentryTokenId, "");
        }
    }

    /// @notice For tests: simulate a transfer where `_safeNotify` happens but
    ///         the on-chain ownerOf check still reports the previous holder.
    bool public spoofOwnerToZero;
    function setSpoofOwnerToZero(bool b) external { spoofOwnerToZero = b; }

    function createLock(uint256 value, uint256 /*duration*/, LockType lockType) external override returns (uint256 tokenId) {
        require(value > 0, "ZeroAmount");
        IERC20(_token).transferFrom(msg.sender, address(this), value);
        tokenId = _nextTokenId++;
        _setOwner(tokenId, msg.sender);
        _lockDetails[tokenId] = LockDetails({
            amount: value,
            startTime: block.timestamp,
            endTime: 0,
            lockType: mintAsPermanentOnCreateLock ? LockType.PERMANENT : lockType
        });
    }

    /// @notice Mint a token directly without a token transfer or receiver callback.
    ///         Matches Hydrex's `_mint` (unsafe) semantics — used by the
    ///         RewardsDistributor mock to simulate the rebase-spawn path.
    function mintTo(address to, uint256 amount, LockType lockType) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _setOwner(tokenId, to);
        _lockDetails[tokenId] = LockDetails({
            amount: amount,
            startTime: block.timestamp,
            endTime: 0,
            lockType: lockType
        });
    }

    /// @notice Mint + invoke onERC721Received. Used to simulate the external
    ///         safeTransferFrom path (which DOES notify the receiver), NOT the
    ///         rebase-spawn path (which uses `_mint` and does NOT notify).
    function mintAndSend(address to, uint256 amount, LockType lockType) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _setOwner(tokenId, to);
        _lockDetails[tokenId] = LockDetails({
            amount: amount,
            startTime: block.timestamp,
            endTime: 0,
            lockType: lockType
        });
        _safeNotify(to, tokenId);
    }

    function increaseAmount(uint256 tokenId, uint256 value) external override {
        require(_owners[tokenId] != address(0), "no token");
        IERC20(_token).transferFrom(msg.sender, address(this), value);
        _lockDetails[tokenId].amount += value;
    }

    function increaseUnlockTime(uint256 tokenId, uint256 /*duration*/, bool permanent) external override {
        increaseUnlockTimeCalls++;
        if (increaseUnlockTimeReverts) revert("increaseUnlockTime failed");
        if (reentryArmed && reentryTarget != address(0)) {
            reentryArmed = false; // one-shot
            // Re-enter the recipient's onERC721Received synchronously while the
            // outer hook is still on the stack. The nonReentrant guard must reject.
            IERC721Receiver(reentryTarget).onERC721Received(address(this), address(0), reentryTokenId, "");
        }
        require(_owners[tokenId] != address(0), "no token");
        // Mock semantics: when invoked from the conversion path, set ROLLING.
        // `permanent` arg is informational here.
        _lockDetails[tokenId].lockType = permanent ? LockType.PERMANENT : LockType.ROLLING;
    }

    function unlockRolling(uint256 tokenId) external override {
        _lockDetails[tokenId].lockType = LockType.NON_PERMANENT;
    }

    function merge(uint256 from, uint256 to) external override {
        require(_owners[from] != address(0) && _owners[to] != address(0), "no token");
        require(from != to, "SameNFT");
        mergeCalls++;
        _lockDetails[to].amount += _lockDetails[from].amount;
        _lockDetails[from].amount = 0;
        _setOwner(from, address(0));
    }

    function totalNftsMinted() external view override returns (uint256) {
        return _nextTokenId - 1;
    }

    /// @dev Mirrors Hydrex semantics: original keeps weights[0]'s share; weights[1..]
    ///      each mint a fresh tokenId of the same lockType to the same owner.
    ///      Last piece receives the rounding remainder.
    function split(uint256[] memory weights, uint256 tokenId) external override {
        require(_owners[tokenId] != address(0), "no token");
        require(weights.length >= 2, "InvalidWeights");
        uint256 totalWeight;
        for (uint256 i = 0; i < weights.length; i++) totalWeight += weights[i];
        require(totalWeight > 0, "InvalidWeights");

        LockDetails memory locked = _lockDetails[tokenId];
        address owner = _owners[tokenId];
        uint256 amountLeft = locked.amount;

        for (uint256 i = 0; i < weights.length; i++) {
            uint256 value = (locked.amount * weights[i]) / totalWeight;
            if (i == weights.length - 1) value = amountLeft;
            amountLeft -= value;
            if (i == 0) {
                _lockDetails[tokenId].amount = value;
            } else {
                uint256 newId = _nextTokenId++;
                _setOwner(newId, owner);
                _lockDetails[newId] = LockDetails({
                    amount: value,
                    startTime: block.timestamp,
                    endTime: 0,
                    lockType: locked.lockType
                });
            }
        }
    }

    // -- test knobs --
    function setIncreaseUnlockTimeReverts(bool b) external { increaseUnlockTimeReverts = b; }
    function setMintAsPermanentOnCreateLock(bool b) external { mintAsPermanentOnCreateLock = b; }

    function armReentry(address to, uint256 tokenId) external {
        reentryArmed = true;
        reentryTarget = to;
        reentryTokenId = tokenId;
    }

    function setOwner(uint256 tokenId, address newOwner) external { _setOwner(tokenId, newOwner); }

    function setLockType(uint256 tokenId, LockType t) external { _lockDetails[tokenId].lockType = t; }

    function setLockAmount(uint256 tokenId, uint256 amount) external { _lockDetails[tokenId].amount = amount; }
}
