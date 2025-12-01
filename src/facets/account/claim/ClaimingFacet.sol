// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {LoanConfig} from "../config/LoanConfig.sol";
/**
 * @title ClaimingFacet
 * @dev Facet that interfaces with voting escrow NFTs
 */
contract ClaimingFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;
    IRewardsDistributor public immutable _rewardsDistributor;
    LoanConfig public immutable _loanConfig;

    constructor(address portfolioFactory, address accountConfigStorage, address votingEscrow, address voter, address rewardsDistributor, address loanConfig) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
        _rewardsDistributor = IRewardsDistributor(rewardsDistributor);
        _loanConfig = LoanConfig(loanConfig);
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external {
        // do not claim launchpad token in this method
        for(uint256 i = 0; i < tokens.length; i++) {
            for(uint256 j = 0; j < tokens[i].length; j++) {
                if(tokens[i][j] == address(0x0000000000000000000000000000000000000000)) {
                    return;
                }
            }
        }
        _voter.claimFees(fees, tokens, tokenId);

        _claimRebase(tokenId);
    }

    function claimRebase(uint256 tokenId) external {
        _claimRebase(tokenId);
    }

    function _claimRebase(uint256 tokenId) internal {
        uint256 claimable = _rewardsDistributor.claimable(tokenId);
        if (claimable > 0) {
            try _rewardsDistributor.claim(tokenId) {
            } catch {
            }
        }
        CollateralManager.updateLockedColleratal(tokenId);
    }

    function claimLaunchpadToken(address tradeContract, bytes calldata tradeData) external {
        require(_accountConfigStorage.isAuthorizedCaller(msg.sender));
        // TODO: Check for user set LAUNCHPAD TOKEN, if so, send directly to the portoflio owner
    }

    function processRewards(uint256 rewardsAmount) external {
        require(_accountConfigStorage.isAuthorizedCaller(msg.sender));
        uint256 totalDebt = CollateralManager.getTotalDebt();
        if(totalDebt > 0) {
            _processActiveBalanceRewards(rewardsAmount);
        } else {
            _processZeroBalanceRewards(rewardsAmount);
        }
    }

    function _processActiveBalanceRewards(uint256 rewardsAmount) internal {
        (uint256 lenderPremium, uint256 treasuryFee) = _loanConfig.getActiveRates();
        uint256 lenderRewards = (rewardsAmount * lenderPremium) / 10000;
        uint256 treasuryRewards = (rewardsAmount * treasuryFee) / 10000;
       
       // TODO: transfer to vault

       // TODO: transfer to treasury

       // TODO: Check for active balance option (increase collateral, or receive token)

       // TODO: with remaining rewards pay down balance

       // TODO: Topup if requested
    }

    function _processZeroBalanceRewards(uint256 rewardsAmount) internal {
        // Check for increase percentage

        // Check for zero balance option
    }

}
