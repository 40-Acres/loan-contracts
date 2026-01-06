// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CollateralStorage} from "../../../storage/CollateralStorage.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {AccessControl} from "../utils/AccessControl.sol";
/**
 * @title VotingEscrowFacet
 * @dev Facet that interfaces with voting escrow NFTs
 */
contract VotingEscrowFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;

    event LockIncreased(uint256 indexed tokenId, uint256 amount, address indexed owner);
    event LockCreated(uint256 indexed tokenId, uint256 amount, address indexed owner);

    constructor(address portfolioFactory, address accountConfigStorage, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        require(votingEscrow != address(0), "Voting escrow address cannot be zero");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
    }

    function increaseLock(uint256 tokenId, uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        // if msg.sender is portfolio manager, use the portfolio owner as the from address, otherwise use the caller
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;
        IERC20(_votingEscrow.token()).transferFrom(from, address(this), amount);
        _votingEscrow.increaseAmount(tokenId, amount);
        CollateralManager.updateLockedCollateral(address(_accountConfigStorage), tokenId, address(_votingEscrow));
        emit LockIncreased(tokenId, amount, from);
    }

    function createLock(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) returns (uint256 tokenId) {
        // if msg.sender is portfolio manager, use the portfolio owner as the from address, otherwise use the caller
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;
        IERC20(_votingEscrow.token()).transferFrom(from, address(this), amount);
        IERC20(_votingEscrow.token()).approve(address(_votingEscrow), amount);
        tokenId = _votingEscrow.createLock(amount, 4 *365 days);
        CollateralManager.addLockedCollateral(address(_accountConfigStorage), tokenId, address(_votingEscrow));
        emit LockCreated(tokenId, amount, from);
    }
    
}

