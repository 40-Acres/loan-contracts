// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {VotingFacet} from "./VotingFacet.sol";
import {SuperchainVotingConfig} from "../config/SuperchainVotingConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UserVotingConfig} from "./UserVotingConfig.sol";
import {IRootVotingRewardsFactory} from "../../../interfaces/IRootVotingRewardsFactory.sol";

/**
 * @title SuperchainVoting
 * @dev Facet that interfaces with superchain voting
 */
contract SuperchainVotingFacet is VotingFacet {
    IERC20 public immutable _weth;
    address public immutable RootMessageBridge = 0xF278761576f45472bdD721EACA19317cE159c011;
    address public immutable ROOT_VOTING_REWARDS_FACTORY = address(0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F);

    SuperchainVotingConfig public immutable _superchainVotingConfig;

    error MinimumWethBalanceNotMet();

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingConfig, address votingEscrow, address voter, address weth)
        VotingFacet(portfolioFactory, portfolioAccountConfig, votingConfig, votingEscrow, voter) 
    {
        require(weth != address(0));
        _superchainVotingConfig = SuperchainVotingConfig(address(votingConfig));
        _weth = IERC20(weth);
    }

    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) public override onlyPortfolioManagerMulticall(_portfolioFactory) {
        for(uint256 i = 0; i < pools.length; i++) {
            if(_superchainVotingConfig.isSuperchainPool(pools[i])) {
                _requireMinimumWethBalance();
                uint256 chainId = _superchainVotingConfig.getSuperchainPoolChainId(pools[i]);
                address recipient = IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(address(this), chainId);
                if(recipient != address(this)) {
                    IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).setRecipient(chainId, address(this));
                }
            }
        }
        super.vote(tokenId, pools, weights);
    }

    function setSuperchainPool(address pool, bool approved, uint256 chainId) public onlyAuthorizedCaller(_portfolioFactory) {
        _superchainVotingConfig.setSuperchainPool(pool, approved, chainId);
        _votingConfig.setApprovedPool(pool, approved);
    }

    function getMinimumWethBalance() public view returns (uint256) {
        return _superchainVotingConfig.getMinimumWethBalance();
    }

    function isSuperchainPool(address pool) public view returns (bool) {
        return _superchainVotingConfig.isSuperchainPool(pool);
    }

    function _requireMinimumWethBalance() internal  {
        uint256 minimumWethBalance = _superchainVotingConfig.getMinimumWethBalance();
        require(minimumWethBalance > 0);
        uint256 balance = _weth.balanceOf(address(this));
        require(balance >= minimumWethBalance, MinimumWethBalanceNotMet());
        _weth.approve(address(RootMessageBridge), balance);
    }
}

