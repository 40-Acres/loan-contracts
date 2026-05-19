// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";
import {HydrexPortfolioFactoryConfig} from "./HydrexPortfolioFactoryConfig.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {UserMarketplaceModule} from "../marketplace/UserMarketplaceModule.sol";
import {AccessControl} from "../utils/AccessControl.sol";

/**
 * @title VeHydrexVotingEscrowFacet
 * @dev Lock-management facet for Hydrex veHYDX.
 *      Restricts createLock to PERMANENT and ROLLING lock types; NON_PERMANENT
 *      is rejected because its weight decays over time and would understate
 *      collateral. Incoming NON_PERMANENT veNFTs are auto-converted to ROLLING
 *      in the receiver hook; if the conversion call reverts, the whole transfer
 *      reverts.
 *
 *      Rebase emissions on a non-PERMANENT lock are minted by Hydrex's
 *      RewardsDistributor as a fresh PERMANENT veNFT to the lock owner. The
 *      receiver hook routes that new veNFT through a per-account "rebase
 *      bucket" pattern: either set as the bucket (if none exists yet) or
 *      merged into the existing bucket. PERMANENT originals have rebase
 *      auto-applied in-place by the RewardsDistributor (no new mint, no bucket).
 */
contract VeHydrexVotingEscrowFacet is AccessControl, IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IHydrexVotingEscrow public immutable _votingEscrow;

    event LockIncreased(uint256 indexed tokenId, uint256 amount, address indexed owner);
    event LockCreated(uint256 indexed tokenId, uint256 amount, IHydrexVotingEscrow.LockType lockType, address indexed owner);
    event LockMerged(uint256 indexed from, uint256 indexed to, uint256 weightIncrease, address indexed owner);
    event LockSplit(uint256 indexed tokenId, uint256[] weights, uint256[] resultingTokenIds, address indexed owner);
    event RebaseBucketAssigned(uint256 indexed tokenId, address indexed owner);
    event RebaseBucketAbsorbed(uint256 indexed from, uint256 indexed to, address indexed owner);

    error ListingActive(uint256 tokenId);
    error LockTypeNotAllowed(IHydrexVotingEscrow.LockType lockType);
    error UnexpectedSender(address sender);
    error SplitPieceBelowMinimum(uint256 tokenId, uint256 amount, uint256 minimum);

    constructor(address portfolioFactory, address votingEscrow) {
        require(portfolioFactory != address(0));
        require(votingEscrow != address(0), "Voting escrow address cannot be zero");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = IHydrexVotingEscrow(votingEscrow);
    }

    /// @notice Create a lock. lockType must be PERMANENT or ROLLING; NON_PERMANENT reverts.
    function createLock(uint256 amount, IHydrexVotingEscrow.LockType lockType)
        external
        returns (uint256 tokenId)
    {
        if (lockType == IHydrexVotingEscrow.LockType.NON_PERMANENT) {
            revert LockTypeNotAllowed(lockType);
        }
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;
        IERC20 underlying = IERC20(_votingEscrow.token());
        underlying.safeTransferFrom(from, address(this), amount);
        underlying.approve(address(_votingEscrow), amount);
        // For PERMANENT and ROLLING, the VE forces endTime = 0; duration is ignored.
        tokenId = _votingEscrow.createLock(amount, 0, lockType);
        _addLockedCollateral(tokenId);
        emit LockCreated(tokenId, amount, lockType, from);
    }

    function increaseLock(uint256 tokenId, uint256 amount) external {
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;
        IERC20 underlying = IERC20(_votingEscrow.token());
        underlying.safeTransferFrom(from, address(this), amount);
        underlying.approve(address(_votingEscrow), amount);
        _votingEscrow.increaseAmount(tokenId, amount);
        _updateLockedCollateral(tokenId);
        emit LockIncreased(tokenId, amount, from);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        virtual
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(_votingEscrow)) {
            revert UnexpectedSender(msg.sender);
        }
        // Defense-in-depth ownership re-check, even though the standard ERC721 hook only
        // fires after _safeTransfer completes the ownership update.
        require(_votingEscrow.ownerOf(tokenId) == address(this), "Token not in portfolio account");

        IHydrexVotingEscrow.LockType lockType = _votingEscrow.lockDetails(tokenId).lockType;
        if (lockType == IHydrexVotingEscrow.LockType.NON_PERMANENT) {
            // Convert to ROLLING. If this reverts (e.g., Hydrex governance changes
            // restrictions later), the whole transfer reverts.
            _votingEscrow.increaseUnlockTime(tokenId, 0, true);
            _addLockedCollateral(tokenId);
        } else if (lockType == IHydrexVotingEscrow.LockType.ROLLING) {
            _addLockedCollateral(tokenId);
        } else {
            _absorbPermanentIntoBucket(tokenId);
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Merge an externally-owned token into a token held by this account.
    function merge(uint256 fromToken, uint256 toToken) external {
        require(_votingEscrow.ownerOf(toToken) == address(this));
        require(_votingEscrow.ownerOf(fromToken) != address(this));
        address owner = _portfolioFactory.ownerOf(address(this));

        // Ensure toToken is tracked as collateral so updateLockedCollateral isn't a no-op
        _addLockedCollateral(toToken);

        uint256 beginningBalance = _votingEscrow.lockDetails(toToken).amount;
        _votingEscrow.merge(fromToken, toToken);
        uint256 weightIncrease = _votingEscrow.lockDetails(toToken).amount - beginningBalance;

        _updateLockedCollateral(toToken);
        emit LockMerged(fromToken, toToken, weightIncrease, owner);
    }

    /// @notice Operator-driven consolidation of two account-owned tokens.
    function mergeInternal(uint256 fromToken, uint256 toToken)
        external
        onlyPortfolioManagerMulticall(_portfolioFactory)
    {
        require(fromToken != toToken, "SameNFT");
        require(_votingEscrow.ownerOf(fromToken) == address(this), "from not in account");
        require(_votingEscrow.ownerOf(toToken) == address(this), "to not in account");
        if (UserMarketplaceModule.hasSaleAuthorization(fromToken)) {
            revert ListingActive(fromToken);
        }
        if (UserMarketplaceModule.hasSaleAuthorization(toToken)) {
            revert ListingActive(toToken);
        }

        address owner = _portfolioFactory.ownerOf(address(this));

        _addLockedCollateral(toToken);

        uint256 beginningBalance = _votingEscrow.lockDetails(toToken).amount;
        _votingEscrow.merge(fromToken, toToken);
        uint256 weightIncrease = _votingEscrow.lockDetails(toToken).amount - beginningBalance;

        _updateLockedCollateral(toToken);
        _removeLockedCollateral(fromToken);

        emit LockMerged(fromToken, toToken, weightIncrease, owner);
    }

    /// @notice Split a lock the account owns into N pieces by weight.
    /// @dev The original tokenId keeps weights[0]'s share; weights[1..n-1] each mint a
    ///      new tokenId of the same lockType. All resulting pieces, including the
    ///      shrunken original, must be at or above the configured minimum
    ///      collateral threshold, otherwise the whole call reverts.
    function split(uint256 tokenId, uint256[] calldata weights)
        external
        onlyPortfolioManagerMulticall(_portfolioFactory)
    {
        require(_votingEscrow.ownerOf(tokenId) == address(this), "Token not in portfolio account");
        if (UserMarketplaceModule.hasSaleAuthorization(tokenId)) {
            revert ListingActive(tokenId);
        }

        address config = address(_portfolioFactory.portfolioFactoryConfig());
        uint256 minimum = PortfolioFactoryConfig(config).getMinimumCollateral();
        address owner = _portfolioFactory.ownerOf(address(this));

        // Hydrex's _createLock uses _mint (unsafe), so onERC721Received does NOT fire
        // for the new pieces. Snapshot the id boundary to identify them after the call.
        uint256 idBefore = _votingEscrow.totalNftsMinted();
        _votingEscrow.split(weights, tokenId);
        uint256 idAfter = _votingEscrow.totalNftsMinted();

        // Refresh the original (its amount shrank by the sum of weights[1..]).
        _updateLockedCollateral(tokenId);
        uint256 originalAmount = _votingEscrow.lockDetails(tokenId).amount;
        if (originalAmount < minimum) {
            revert SplitPieceBelowMinimum(tokenId, originalAmount, minimum);
        }

        uint256[] memory resulting = new uint256[](idAfter - idBefore);
        for (uint256 i = 0; i < resulting.length; i++) {
            uint256 newId = idBefore + 1 + i;
            uint256 amt = _votingEscrow.lockDetails(newId).amount;
            if (amt < minimum) {
                revert SplitPieceBelowMinimum(newId, amt, minimum);
            }
            _addLockedCollateral(newId);
            resulting[i] = newId;
        }

        emit LockSplit(tokenId, weights, resulting, owner);
    }

    function _absorbPermanentIntoBucket(uint256 incomingTokenId) internal {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        HydrexPortfolioFactoryConfig hydrexConfig = HydrexPortfolioFactoryConfig(config);
        uint256 bucket = hydrexConfig.getRebaseTokenId(address(this));
        address owner = _portfolioFactory.ownerOf(address(this));

        bool bucketValid =
            bucket != 0 && bucket != incomingTokenId && _votingEscrow.ownerOf(bucket) == address(this);

        if (!bucketValid) {
            hydrexConfig.setRebaseTokenId(incomingTokenId);
            _addLockedCollateralUnchecked(incomingTokenId);
            emit RebaseBucketAssigned(incomingTokenId, owner);
        } else {
            _votingEscrow.merge(incomingTokenId, bucket);
            _updateLockedCollateral(bucket);
            emit RebaseBucketAbsorbed(incomingTokenId, bucket, owner);
        }
    }

    function _addLockedCollateral(uint256 tokenId) internal virtual {
        HydrexCollateralManager.addLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _addLockedCollateralUnchecked(uint256 tokenId) internal virtual {
        HydrexCollateralManager.addLockedCollateralUnchecked(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _updateLockedCollateral(uint256 tokenId) internal virtual {
        HydrexCollateralManager.updateLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _removeLockedCollateral(uint256 tokenId) internal virtual {
        HydrexCollateralManager.removeLockedCollateral(
            tokenId, address(_portfolioFactory.portfolioFactoryConfig()), address(_votingEscrow)
        );
    }
}
