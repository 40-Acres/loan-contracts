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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";
import {UserClaimingConfig} from "./UserClaimingConfig.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {SwapMod} from "../swap/SwapMod.sol";
/**
 * @title ClaimingFacet
 * @dev Facet that interfaces with voting escrow NFTs
 */
contract ClaimingFacet is AccessControl {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;
    IRewardsDistributor public immutable _rewardsDistributor;
    LoanConfig public immutable _loanConfig;
    SwapConfig public immutable _swapConfig;
    IERC4626 public immutable _vault;
    error InvalidClaim(address token);

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig, address swapConfig, address vault) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
        _rewardsDistributor = IRewardsDistributor(rewardsDistributor);
        _loanConfig = LoanConfig(loanConfig);
        _swapConfig = SwapConfig(swapConfig);
        // vault can be zero address if there is no vault (no lending)
        _vault = IERC4626(vault);
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) public virtual {
        // do not claim launchpad token in this method
        address launchpadToken = UserClaimingConfig.getLaunchPadTokenForCurrentEpoch(tokenId);
        for(uint256 i = 0; i < tokens.length; i++) {
            for(uint256 j = 0; j < tokens[i].length; j++) {
                if(tokens[i][j] == launchpadToken) { 
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
        CollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
    }

    function claimLaunchpadToken(address[] calldata fees, address[][] calldata tokens, uint256 tokenId, address tradeContract, bytes calldata tradeData, uint256 expectedOutputAmount) virtual external onlyAuthorizedCaller(_portfolioFactory) {
        IERC20 launchpadToken = IERC20(UserClaimingConfig.getLaunchPadTokenForCurrentEpoch(tokenId));
        if(address(launchpadToken) == address(0)) {
            revert("Launchpad token not set");
        }

        uint256 launchpadTokenBalanceBefore = launchpadToken.balanceOf(address(this));
        // claim fees for launchpad token
        _voter.claimFees(fees, tokens, tokenId);

        // ensure only launchpad token is being claimed
        for(uint256 i = 0; i < tokens.length; i++) {
            for(uint256 j = 0; j < tokens[i].length; j++) {
                require(tokens[i][j] == address(launchpadToken), InvalidClaim(tokens[i][j]));
            }
        }

        // only claim launchpad token if user wants to receive it directly
        // TODO FIX
        if(!UserClaimingConfig.getReceiveLaunchPadTokenForThisEpoch()) {
            return;
        }

        uint256 totalDebt = CollateralManager.getTotalDebt();
        // if account has a balance, swap and pay lenders/treasury
        if(totalDebt > 0) {
            require(tradeContract != address(0));
            require(tradeData.length > 0);
            require(expectedOutputAmount > 0);
            IERC4626 vault = _vault;
            address outputToken = vault.asset();
            // Calculate the actual amount of launchpad token received after claiming fees
            uint256 launchpadTokenBalanceAfter = launchpadToken.balanceOf(address(this));
            uint256 launchpadTokenAmountToSwap = launchpadTokenBalanceAfter - launchpadTokenBalanceBefore;
            require(launchpadTokenAmountToSwap > 0, "No launchpad token to swap");
            uint256 outputAmount = SwapMod.swap(address(_swapConfig), tradeContract, tradeData, address(launchpadToken), launchpadTokenAmountToSwap, outputToken, expectedOutputAmount);
            require(address(vault) != address(0), "Vault not set");

            // get treasury fee and lender premium
            (uint256 lenderPremium, uint256 treasuryFee) = _loanConfig.getActiveRates();

            // from the total amount of output amount, calculate the treasury fee and lender premium
            uint256 totalFees = treasuryFee + lenderPremium;

            uint256 treasuryFeeAmount = (outputAmount * treasuryFee) / totalFees;
            uint256 lenderPremiumAmount = outputAmount - treasuryFeeAmount;
            address loanContract = _portfolioAccountConfig.getLoanContract();
            IERC20(outputToken).safeTransfer(ILoan(loanContract).owner(), treasuryFeeAmount);
            IERC20(outputToken).safeTransfer(address(vault), lenderPremiumAmount);
        }

        // send remaining launchpad token to portfolio owner
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        launchpadToken.safeTransfer(portfolioOwner, launchpadToken.balanceOf(address(this)));
    }
}

