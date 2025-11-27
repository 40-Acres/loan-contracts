// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import { Loan } from "../LoanV2.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import { ProtocolTimeLibrary } from "../libraries/ProtocolTimeLibrary.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import { console } from "forge-std/console.sol";
import {IXPharaohLoan} from "./interfaces/IXPharaohLoan.sol";
import {PortfolioFactory} from "../accounts/PortfolioFactory.sol";
import {console} from "forge-std/console.sol";

interface IPharaohFacet {
    function pharaohIncreaseCollateral(uint256 amount) external;
}

contract PharaohLoanV2 is Loan {
    /* ORACLE */
    /**
     * @notice Confirms the price of USDC is $1.
     * @dev This function checks the latest round data from the Chainlink price feed for USDC.
     * @return bool indicating whether the price of USDC is greater than or equal to $0.999.
     */
    function confirmUsdcPrice() override virtual internal view returns (bool) {
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
     * @notice Allows user to merge their veNFT into another veNFT.
     * @dev This function can only be called by the owner of the veNFT being merged.
     * @param from The ID of the token to merge from.
     * @param to The ID of the token to merge to.
     */
    function merge(uint256 from, uint256 to) override public {
        require(_ve.ownerOf(to) == address(this));
        require(_ve.ownerOf(from) == msg.sender);
        LoanInfo storage loan = _loanDetails[to];
        require(loan.borrower == msg.sender);
        uint256 beginningBalance = _getLockedAmount(to);
        _ve.transferFrom(msg.sender, address(this), from);
        _ve.merge(from, to);
        uint256 weightIncrease = _getLockedAmount(to) - beginningBalance;
        loan.weight += weightIncrease;
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

    function _getLockedAmount(uint256 tokenId) internal view override returns (uint256) {
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(address(_ve)).locked(tokenId);
        if (lockedBalance.end <= block.timestamp) {
            return 0;
        }
        require(lockedBalance.amount >= 0);
        return uint256(uint128(lockedBalance.amount));
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
    function claim(uint256 tokenId, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) public override returns (uint256 totalRewards) {
        vote(tokenId);
        return super.claim(tokenId, fees, tokens, tradeData, allocations);
    }

    /**
     * @notice Returns the address of the ODOS Router contract.
     * @dev This function is used to interact with the ODOS Router for trading and swapping tokens.
     * @return The address of the ODOS Router contract.
     */
    function odosRouter() public override pure returns (address) {
        return 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC; // ODOS Router address
    }


    /**
     * @notice Returns the rewards for next epoch.
     * @return The amount of rewards for the next epoch.
     */
    function nextEpochReward() public view returns (uint256) {
        return _rewardsPerEpoch[ProtocolTimeLibrary.epochNext(block.timestamp)];
    }

    /**
     * @notice Records the rewards for the current epoch.
     * @dev This function adds the specified rewards to the total rewards for the current epoch.
     * @param rewards The amount of rewards to record.
     */
    function recordRewards(uint256 rewards, address borrower, uint256 tokenId) internal override {
        if (rewards > 0) {
            _rewardsPerEpoch[ProtocolTimeLibrary.epochNext(block.timestamp)] += rewards;
            emit RewardsReceived(ProtocolTimeLibrary.epochNext(block.timestamp), rewards, borrower, tokenId);
        }
    }

    /**
     * @notice Transfers a specified amount of USDC from the caller to the vault and records the rewards.
     * @dev This function requires the caller to have approved the contract to transfer the specified amount of USDC.
     * @param amount The amount of USDC to transfer to the vault and record as rewards.
     */
    function incentivizeVault(uint256 amount) override public {
        _asset.transferFrom(msg.sender, _vault, amount);
        _rewardsPerEpoch[currentEpochStart()] += amount;
        emit RewardsReceived(currentEpochStart(), amount, msg.sender, type(uint256).max);
    }
    

    function getOutstandingCapital(uint256 tokenId) public view returns (uint256, uint256, uint256) {
        return (
            _loanDetails[tokenId].outstandingCapital,
            _loanDetails[tokenId].unpaidFees,
            _loanDetails[tokenId].balance
        );
    }

    /**
     * @notice Migrates an NFT from Pharaoh Loan to XPharaoh Loan.
     * @dev This function kicks off the migration process by approving the veNFT to the XPharaoh Loan contract.
     * @param tokenId The ID of the NFT to migrate.
     * @param xPharaohLoan The address of the XPharaoh Loan contract.
     */
    function migrateNft(uint256 tokenId, address xPharaohLoan, address portfolioFactory) public onlyOwner {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower != address(0), "no borrower");
        address portfolio = PortfolioFactory(portfolioFactory).portfolioOf(loan.borrower);
        (uint256 previousBalance,) = IXPharaohLoan(xPharaohLoan).getLoanDetails(portfolio);
        _voter.reset(tokenId);
        IERC721(address(_ve)).approve(xPharaohLoan, tokenId);
        IXPharaohLoan(xPharaohLoan).migrateNft(loan.borrower, tokenId, loan.balance, loan.outstandingCapital, loan.preferredToken, loan.increasePercentage, loan.topUp, uint8(loan.zeroBalanceOption), loan.unpaidFees);
        // Get the portfolio address again after migration (it might have been created)
        portfolio = PortfolioFactory(portfolioFactory).portfolioOf(loan.borrower);
        (uint256 postBalance,) = IXPharaohLoan(xPharaohLoan).getLoanDetails(portfolio);
        require(previousBalance + loan.balance == postBalance);
        delete _loanDetails[tokenId];
    }
}
