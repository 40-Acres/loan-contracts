// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {AccessControl} from "../utils/AccessControl.sol";

/**
 * @title DynamicVotingEscrowFacet
 * @dev VotingEscrowFacet variant that uses DynamicCollateralManager for storage.
 */
contract DynamicVotingEscrowFacet is AccessControl, IERC721Receiver {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _accountConfigStorage;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;

    event LockIncreased(uint256 indexed tokenId, uint256 amount, address indexed owner);
    event LockCreated(uint256 indexed tokenId, uint256 amount, address indexed owner);
    event LockMerged(uint256 indexed from, uint256 indexed to, uint256 weightIncrease, address indexed owner);

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(votingEscrow != address(0), "Voting escrow address cannot be zero");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
    }

    function increaseLock(uint256 tokenId, uint256 amount) external {
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;
        IERC20 votingEscrow = IERC20(_votingEscrow.token());
        votingEscrow.safeTransferFrom(from, address(this), amount);
        votingEscrow.approve(address(_votingEscrow), amount);
        _votingEscrow.increaseAmount(tokenId, amount);
        DynamicCollateralManager.updateLockedCollateral(address(_accountConfigStorage), tokenId, address(_votingEscrow));
        emit LockIncreased(tokenId, amount, from);
    }

    function createLock(uint256 amount) external returns (uint256 tokenId) {
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;
        IERC20 votingEscrow = IERC20(_votingEscrow.token());
        votingEscrow.safeTransferFrom(from, address(this), amount);
        votingEscrow.approve(address(_votingEscrow), amount);
        tokenId = _votingEscrow.createLock(amount, 4 *365 days);
        DynamicCollateralManager.addLockedCollateral(address(_accountConfigStorage), tokenId, address(_votingEscrow));
        emit LockCreated(tokenId, amount, from);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(_votingEscrow)) {
            DynamicCollateralManager.addLockedCollateral(address(_accountConfigStorage), tokenId, address(_votingEscrow));
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function merge(uint256 fromToken, uint256 toToken) external {
        require(_votingEscrow.ownerOf(toToken) == address(this));
        require(_votingEscrow.ownerOf(fromToken) != address(this));
        address owner = _portfolioFactory.ownerOf(address(this));
        int128 beginningBalance = _votingEscrow.locked(toToken).amount;
        _votingEscrow.merge(fromToken, toToken);
        int128 weightIncrease = _votingEscrow.locked(toToken).amount - beginningBalance;
        require(weightIncrease >= 0, "Negative weight increase");
        // Remove stale collateral record for fromToken (burned after merge)
        DynamicCollateralManager.removeLockedCollateral(fromToken, address(_accountConfigStorage));
        DynamicCollateralManager.updateLockedCollateral(address(_accountConfigStorage), toToken, address(_votingEscrow));
        emit LockMerged(fromToken, toToken, uint256(uint128(weightIncrease)), owner);
    }

}
