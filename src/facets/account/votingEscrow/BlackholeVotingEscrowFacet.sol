// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IVotingEscrow} from "../../../Blackhole/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {UserMarketplaceModule} from "../marketplace/UserMarketplaceModule.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {IVoter} from "../../../Blackhole/interfaces/IVoter.sol";

/**
 * @title BlackholeVotingEscrowFacet
 * @dev VotingEscrowFacet adapted for Blackhole's veBlack contracts.
 *      Key differences from standard VotingEscrowFacet:
 *      - Uses increase_amount() instead of increaseAmount()
 *      - Uses create_lock_for() instead of createLock()
 *      - Accounts for Super Massive NFT boost in locked amount via balanceOfNFT()
 */
contract BlackholeVotingEscrowFacet is AccessControl, IERC721Receiver {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;

    event LockIncreased(uint256 indexed tokenId, uint256 amount, address indexed owner);
    event LockCreated(uint256 indexed tokenId, uint256 amount, address indexed owner);
    event LockMerged(uint256 indexed from, uint256 indexed to, uint256 weightIncrease, address indexed owner);

    error ListingActive(uint256 tokenId);

    constructor(address portfolioFactory, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(votingEscrow != address(0));
        require(voter != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
    }

    function increaseLock(uint256 tokenId, uint256 amount) external {
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;
        IERC20 token = IERC20(_votingEscrow.token());
        token.safeTransferFrom(from, address(this), amount);
        token.approve(address(_votingEscrow), amount);
        _votingEscrow.increase_amount(tokenId, amount);
        CollateralManager.updateLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow));
        emit LockIncreased(tokenId, amount, from);
    }

    function createLock(uint256 amount) external returns (uint256 tokenId) {
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;
        IERC20 token = IERC20(_votingEscrow.token());
        token.safeTransferFrom(from, address(this), amount);
        token.approve(address(_votingEscrow), amount);
        tokenId = _votingEscrow.create_lock_for(amount, 4 * 365 days, address(this), true);
        CollateralManager.addLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow));
        emit LockCreated(tokenId, amount, from);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(_votingEscrow)) {
            CollateralManager.addLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow));
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function merge(uint256 fromToken, uint256 toToken) external {
        require(_votingEscrow.ownerOf(toToken) == address(this));
        require(_votingEscrow.ownerOf(fromToken) != address(this));
        address config = address(_portfolioFactory.portfolioFactoryConfig());

        CollateralManager.addLockedCollateral(config, toToken, address(_votingEscrow));

        uint256 beginningBalance = _getLockedAmount(toToken);
        _votingEscrow.transferFrom(msg.sender, address(this), fromToken);
        _votingEscrow.merge(fromToken, toToken);

        uint256 endBalance = _getLockedAmount(toToken);
        uint256 weightIncrease = endBalance - beginningBalance;

        CollateralManager.updateLockedCollateral(config, toToken, address(_votingEscrow));
        emit LockMerged(fromToken, toToken, weightIncrease, _portfolioFactory.ownerOf(address(this)));
    }

    function mergeInternal(uint256 fromToken, uint256 toToken) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(fromToken != toToken, "SameNFT");
        require(_votingEscrow.ownerOf(fromToken) == address(this), "from not in account");
        require(_votingEscrow.ownerOf(toToken) == address(this), "to not in account");
        if (UserMarketplaceModule.hasSaleAuthorization(fromToken)) {
            revert ListingActive(fromToken);
        }
        if (UserMarketplaceModule.hasSaleAuthorization(toToken)) {
            revert ListingActive(toToken);
        }

        address config = address(_portfolioFactory.portfolioFactoryConfig());

        CollateralManager.addLockedCollateral(config, toToken, address(_votingEscrow));

        _voter.reset(fromToken);

        uint256 beginningBalance = _getLockedAmount(toToken);
        _votingEscrow.merge(fromToken, toToken);
        uint256 endBalance = _getLockedAmount(toToken);
        uint256 weightIncrease = endBalance - beginningBalance;

        CollateralManager.removeLockedCollateral(fromToken, config, address(_votingEscrow));
        CollateralManager.updateLockedCollateral(config, toToken, address(_votingEscrow));

        emit LockMerged(fromToken, toToken, weightIncrease, _portfolioFactory.ownerOf(address(this)));
    }

    /**
     * @dev Gets the effective locked amount for a token, accounting for SM NFT boost.
     *      Returns the higher of balanceOfNFT (includes boost) and raw locked amount.
     */
    function _getLockedAmount(uint256 tokenId) internal view returns (uint256) {
        IVotingEscrow.LockedBalance memory lockedBalance = _votingEscrow.locked(tokenId);
        require(lockedBalance.amount >= 0);
        uint256 rawAmount = uint256(uint128(lockedBalance.amount));
        uint256 veBalance = _votingEscrow.balanceOfNFT(tokenId);
        return veBalance > rawAmount ? veBalance : rawAmount;
    }
}
