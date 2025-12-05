// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CollateralStorage} from "../../../storage/CollateralStorage.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
/**
 * @title VotingEscrowFacet
 * @dev Facet that interfaces with voting escrow NFTs
 */
contract VotingEscrowFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;

    constructor(address portfolioFactory, address accountConfigStorage, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        require(votingEscrow != address(0), "Voting escrow address cannot be zero");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
    }

    function increaseLock(uint256 tokenId, uint256 amount) external {
        IERC20(_votingEscrow.token()).transferFrom(msg.sender, address(this), amount);
        _votingEscrow.increaseAmount(tokenId, amount);
        CollateralManager.updateLockedCollateral(tokenId, address(_votingEscrow));
    }
}

