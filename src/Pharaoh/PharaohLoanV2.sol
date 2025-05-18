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

    /**
     * @notice Allows the owner of a token to request a loan by locking the token as collateral.
     * @dev The function ensures that the token is locked permanently and transfers ownership of the token
     *      to the contract. It also initializes loan details for the token and optionally increases the loan amount.
     * @param tokenId The ID of the token to be used as collateral.
     * @param amount The amount of the loan to be requested. If 0, no loan amount is added initially.
     * @param zeroBalanceOption The option specifying how zero balance scenarios should be handled.
     * @param increasePercentage The percentage of the rewards to reinvest into venft.
     * @param topUp Indicates whether to top up the loan amount.
     */
    function requestLoan(
        uint256 tokenId,
        uint256 amount,
        ZeroBalanceOption zeroBalanceOption,
        uint256 increasePercentage,
        address preferredToken,
        bool topUp,
        bool optInCommunityRewards
    ) public override {
        // require the msg.sender to be the owner of the token
        require(_ve.ownerOf(tokenId) == msg.sender);
        

        _loanDetails[tokenId] = LoanInfo({
            balance: 0,
            borrower: msg.sender,
            timestamp: block.timestamp,
            outstandingCapital: 0,
            tokenId: tokenId,
            zeroBalanceOption: zeroBalanceOption,
            pools: new address[](0),
            voteTimestamp: 0,
            claimTimestamp: 0,
            weight: 0,
            unpaidFees: 0,
            preferredToken: preferredToken,
            increasePercentage: increasePercentage,
            topUp: topUp,
            optInCommunityRewards: optInCommunityRewards

        });

        vote(tokenId);

        // transfer the token to the contract
        _ve.transferFrom(msg.sender, address(this), tokenId);
        require(_ve.ownerOf(tokenId) == address(this));
        emit CollateralAdded(tokenId, msg.sender, zeroBalanceOption);


        require(increasePercentage <= 10000);
        if(preferredToken != address(0)) {
            require(isApprovedToken(preferredToken), "Token not approved");
        }
        
        _loanDetails[tokenId].weight = _ve.balanceOfNFTAt(tokenId, block.timestamp);
        addTotalWeight(_loanDetails[tokenId].weight);

        // if user selects topup option, increase to the max loan amount
        if(topUp) {
            (amount,) = getMaxLoan(tokenId);
        }

        if (amount > 0) {
            increaseLoan(tokenId, amount);
        }
    }

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
    function _vote(uint256 tokenId, address[] memory pools, uint256[] memory weights) internal override {
        // ensure the token is locked permanently
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(address(_ve)).locked(tokenId);
        if (lockedBalance.end < ProtocolTimeLibrary.epochNext(block.timestamp)) {
           IVotingEscrow(address(_ve)).increaseUnlockTime(tokenId, 126144000); // 4 years
        }

        LoanInfo storage loan = _loanDetails[tokenId];
        if(loan.borrower == msg.sender && pools.length > 0) {
            // not within try catch because we want to revert if the transaction fails so the user can try again
            _voter.vote(tokenId, pools, weights); 
            loan.voteTimestamp = block.timestamp;
        }
        // must vote each epoch, user are able to change their vote so we vote once per epoch if the user has not voted
        bool isActive = ProtocolTimeLibrary.epochStart(loan.voteTimestamp) == ProtocolTimeLibrary.epochStart(block.timestamp);
        if(isActive) {
            return; // if the user has manually voted, we don't want to override their vote
        }
        if(_withinVotingWindow()) {
            try _voter.vote(tokenId, _defaultPools, _defaultWeights) {
                loan.voteTimestamp = block.timestamp;
                return;
            } catch { }
        } 
    }

}