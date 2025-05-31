// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import { Loan } from "../LoanV2.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import { ProtocolTimeLibrary } from "../libraries/ProtocolTimeLibrary.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

contract PharaohLoanV2 is Loan {
    /* ORACLE */
    /**
     * @notice Confirms the price of USDC is $1.
     * @dev This function checks the latest round data from the Chainlink price feed for USDC.
     * @return bool indicating whether the price of USDC is greater than or equal to $0.999.
     */
    function confirmUsdcPrice() override internal view returns (bool) {
        (
            /* uint80 roundID */,
            int answer ,
            /*uint startedAt*/,
            uint256 timestamp,
            /*uint80 answeredInRound*/

        ) = AggregatorV3Interface(address(0xF096872672F44d6EBA71458D74fe67F9a77a23B9)).latestRoundData();

        // add staleness check, data updates every 24 hours
        require(timestamp > block.timestamp - 25 hours);
        // confirm price of usdc is $1
        return answer >= 99900000;
    }

    
    function _swapToToken(
        uint256 amountIn,
        address fromToken,
        address toToken,
        address borrower
    ) internal override returns (uint256 amountOut) {
        require(fromToken != address(_ve)); // Prevent swapping veNFT
        if (fromToken == toToken || amountIn == 0) {
            return amountIn;
        }
        IERC20(fromToken).approve(address(_aeroRouter), 0); // reset approval first
        IERC20(fromToken).approve(address(_aeroRouter), amountIn);
        ISwapper swapper = ISwapper(getSwapper());
        IRouter.route[] memory routes = ISwapper(swapper).getBestRoute(fromToken, toToken, amountIn);
        uint256 minimumAmountOut = ISwapper(swapper).getMinimumAmountOut(routes, amountIn);
        
        if (minimumAmountOut == 0) {
            // send to borrower if the swap returns 0
            IERC20(fromToken).transfer(borrower, amountIn);
            return 0;
        }
        uint256[] memory amounts = IRouter(address(_aeroRouter)).swapExactTokensForTokens(
                amountIn,
                minimumAmountOut,
                routes,
                address(this),
                block.timestamp
            );
        return amounts[amounts.length - 1];
    }


    /**
     * @dev Internal function to handle voting for a specific loan.
     * @param tokenId The ID of the loan (NFT) for which the vote is being cast.
     * @param pools An array of addresses representing the pools to vote on.
     * @param weights An array of uint256 values representing the weights of the pools.
     */
    function _vote(uint256 tokenId, address[] memory pools, uint256[] memory weights) internal override returns (bool) {
        _lock(tokenId);
        LoanInfo storage loan = _loanDetails[tokenId];
        if(loan.borrower == msg.sender && pools.length > 0) {
            // not within try catch because we want to revert if the transaction fails so the user can try again
            _voter.vote(tokenId, pools, weights); 
            loan.voteTimestamp = block.timestamp;
            return true;
        }
        // must vote each epoch, user are able to change their vote so we vote once per epoch if the user has not voted
        bool isActive = ProtocolTimeLibrary.epochStart(loan.voteTimestamp) == ProtocolTimeLibrary.epochStart(block.timestamp);
        if(!isActive) {
            try _voter.vote(tokenId, _defaultPools, _defaultWeights) {
                loan.voteTimestamp = block.timestamp;
                return true;
            } catch { }
        }
        return false;
    }

    /**
     * @dev Internal function to lock the voting escrow for a specific loan.
     * @param tokenId The ID of the loan (NFT) for which the lock is being applied.
     */
    function _lock(uint256 tokenId) internal override {
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(address(_ve)).locked(tokenId);
        if (lockedBalance.end < ProtocolTimeLibrary.epochStart(block.timestamp) + 125539200) {
           IVotingEscrow(address(_ve)).increaseUnlockTime(tokenId, 126144000);
        }
    }

    /**
     * @notice Resets the vote for a specific loan.
     * @param tokenId The ID of the loan (NFT) for which the vote is being reset.
     */
    function reset(uint256 tokenId) public  {
        // reset the vote timestamp so the user can claim collateral
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender);
        require(loan.balance == 0);
        loan.voteTimestamp = 0;
        _voter.reset(tokenId);
    }


    /**
     * @notice Claims rewards for a specific loan.
     * @param tokenId The ID of the loan (NFT) for which rewards are being claimed.
     * @param fees An array of addresses representing the fee recipients.
     * @param tokens An array of arrays of addresses representing the tokens to claim.
     * @return totalRewards The total amount of rewards claimed.
     */
    function claim(uint256 tokenId, address[] calldata fees, address[][] calldata tokens) public override returns (uint256 totalRewards) {
        vote(tokenId);
        // dont claim rewards unless the user has been in the pool for over an hour, or doesnt have a loan
        LoanInfo storage loan = _loanDetails[tokenId];
        return super.claim(tokenId, fees, tokens);
    }
}