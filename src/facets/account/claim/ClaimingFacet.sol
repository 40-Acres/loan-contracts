// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {LoanConfig} from "../config/LoanConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";
import {UserClaimingConfig} from "./UserClaimingConfig.sol";

/**
 * @title ClaimingFacet
 * @dev Facet that interfaces with voting escrow NFTs
 */
contract ClaimingFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;
    IRewardsDistributor public immutable _rewardsDistributor;
    LoanConfig public immutable _loanConfig;

    error InvalidClaim(address token);

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
        _rewardsDistributor = IRewardsDistributor(rewardsDistributor);
        _loanConfig = LoanConfig(loanConfig);
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) public {
        // do not claim launchpad token in this method
        for(uint256 i = 0; i < tokens.length; i++) {
            for(uint256 j = 0; j < tokens[i].length; j++) {
                if(tokens[i][j] == UserClaimingConfig.getLaunchPadTokenForCurrentEpoch(tokenId)) { 
                    return;
                }
            }
        }
        _voter.claimFees(fees, tokens, tokenId);

        claimRebase(tokenId);
    }

    function claimRebase(uint256 tokenId) public {
        uint256 claimable = _rewardsDistributor.claimable(tokenId);
        if (claimable > 0) {
            try _rewardsDistributor.claim(tokenId) {
            } catch {
            }
        }
        CollateralManager.updateLockedColleratal(tokenId);
    }

    function claimLaunchpadToken(address[] calldata fees, address[][] calldata tokens, uint256 tokenId, address tradeContract, bytes calldata tradeData, address outputToken, uint256 expectedOutputAmount) external {
        require(_portfolioAccountConfig.isAuthorizedCaller(msg.sender));
        claimFees(fees, tokens, tokenId);

        address launchpadToken = UserClaimingConfig.getLaunchPadTokenForCurrentEpoch(tokenId);
        if(launchpadToken == address(0)) {
            return;
        }
        // ensure only launchpad token is being claimed
        for(uint256 i = 0; i < tokens.length; i++) {
            for(uint256 j = 0; j < tokens[i].length; j++) {
                require(tokens[i][j] == address(launchpadToken), InvalidClaim(tokens[i][j]));
            }
        }

        IERC20(launchpadToken).approve(address(tradeContract), IERC20(launchpadToken).balanceOf(address(this)));
        (bool success, ) = tradeContract.call(tradeData);
        require(success);
        uint256 outputAmount = IERC20(outputToken).balanceOf(address(this));
        require(outputAmount >= expectedOutputAmount, "Output amount is less than expected");


        // if has a balance send treasury fee to the vault

        // remove approvals
        IERC20(launchpadToken).approve(address(tradeContract), 0);
    }

    function processRewards(uint256 rewardsAmount, address asset) external {
        require(_portfolioAccountConfig.isAuthorizedCaller(msg.sender));
        uint256 totalDebt = CollateralManager.getTotalDebt();
        // if have a balance, use loan contract to handle funds
        if(totalDebt > 0) {
            require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount);
            address loanContract = _portfolioAccountConfig.getLoanContract();
            require(loanContract != address(0));
            IERC20(asset).approve(loanContract, rewardsAmount);
            ILoan(loanContract).handleActiveLoanPortfolioAccount(rewardsAmount);
        }

        // if no loan, use config to handle payments
    }
}

