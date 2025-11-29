// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {VotingFacet} from "./VotingFacet.sol";
import {SuperchainVotingConfigStorage} from "./SuperchainVotingConfigStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SuperchainVoting
 * @dev Facet that interfaces with superchain voting
 */
contract SuperchainVotingFacet is VotingFacet {
    IERC20 public immutable _weth = IERC20(0x4200000000000000000000000000000000000006);
    address public immutable RootMessageBridge = 0xF278761576f45472bdD721EACA19317cE159c011;
    SuperchainVotingConfigStorage public immutable _superchainVotingConfigStorage;
    bool public superchainInitialized = false;

    error MinimumWethBalanceNotMet();

    constructor(address portfolioFactory, address accountConfigStorage, address votingConfigStorage, address votingEscrow, address voter)
        VotingFacet(portfolioFactory, accountConfigStorage, votingConfigStorage, votingEscrow, voter) 
    {
        _superchainVotingConfigStorage = SuperchainVotingConfigStorage(address(votingConfigStorage));
    }

    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external override {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        for(uint256 i = 0; i < pools.length; i++) {
            if(!superchainInitialized) {
                initializeSuperchain();
            }
            bool isSuperchainPool = _superchainVotingConfigStorage.isApprovedPool(pools[i]);
            if(isSuperchainPool) {
                requireMinimumWethBalance();
            }
        }
       _vote(tokenId, pools, weights);
    }

    function initializeSuperchain() public {
        require(!superchainInitialized);
        requireMinimumWethBalance();
        superchainInitialized = true;
    }

    function requireMinimumWethBalance() internal  {
        uint256 minimumWethBalance = _superchainVotingConfigStorage.getMinimumWethBalance();
        require(minimumWethBalance > 0);
        uint256 balance = _weth.balanceOf(address(this));
        require(balance >= minimumWethBalance, MinimumWethBalanceNotMet());
        _weth.approve(address(RootMessageBridge), balance);
    }
}

