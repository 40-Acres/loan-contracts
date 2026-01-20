// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import { Loan } from "../LoanV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IGaugeManager} from "./interfaces/IGaugeManager.sol";
import { ProtocolTimeLibrary } from "../libraries/ProtocolTimeLibrary.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import { IGaugeManager } from "./interfaces/IGaugeManager.sol";
import { IRewardsDistributor } from "../interfaces/IRewardsDistributor.sol";
import { ISwapper } from "../interfaces/ISwapper.sol";
import { IVoter } from "../interfaces/IVoter.sol";

contract BlackholeLoanV2 is Loan {
    // Blackhole-specific state variables
    IGaugeManager internal constant _gaugeManager = IGaugeManager(0x59aa177312Ff6Bdf39C8Af6F46dAe217bf76CBf6);
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
        addTotalWeight(weightIncrease);
        loan.weight += weightIncrease;
    }

    /**
     * @dev Internal function to lock the voting escrow for a specific loan.
     * @param tokenId The ID of the loan (NFT) for which the lock is being applied.
     */
    function _lock(uint256 tokenId) internal override {
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(address(_ve)).locked(tokenId);
        if (!lockedBalance.isPermanent) {
            require(lockedBalance.end > block.timestamp);
            IVotingEscrow(address(_ve)).lockPermanent(tokenId);
        }
    }



    /**
     * @dev Internal function to increase the
      NFT-related value for a loan.
     * @param loan The LoanInfo struct containing details of the loan.
     * @param allocation The amount  to be allocated for increasing the veNFT balance.
     * @return spent The amount spent to increase the veNFT balance, or 0 if no increase is made.
     */
    function _increaseNft(LoanInfo storage loan, uint256 allocation, bool takeFees) internal override returns (uint256 spent) {
        if(loan.increasePercentage > 0 && allocation == 0) {
            revert(); // Should be an allocation if increasePercentage is set
        }
        if(allocation == 0) {
            return 0;
        }
        _aero.approve(address(_ve), allocation);
        uint256 managedNft = getManagedNft();
        uint256 tokenToIncrease = loan.tokenId;
        IVotingEscrow(address(_ve)).increase_amount(tokenToIncrease, allocation);
        emit VeNftIncreased(currentEpochStart(), loan.borrower, tokenToIncrease, allocation, loan.tokenId);
        addTotalWeight(allocation);
        loan.weight += allocation;
        return allocation;
    }


    /**
     * @notice Increases the locked amount of a veNFT token.
     * @dev This function locks tokens into the veNFT associated with the given token ID.
     * @param tokenId The ID of the veNFT whose amount is to be increased.
     * @param amount The amount of tokens to be added to the veNFT.
     */

    function increaseAmount(uint256 tokenId, uint256 amount) override public {
        require(_ve.ownerOf(tokenId) == address(this));
        require(amount > 0);
        require(_aero.transferFrom(msg.sender, address(this), amount));
        _aero.approve(address(_ve), amount);
        IVotingEscrow(address(_ve)).increase_amount(tokenId, amount);
        emit VeNftIncreased(currentEpochStart(), msg.sender, tokenId, amount, tokenId);
        addTotalWeight(amount);
        LoanInfo storage loan = _loanDetails[tokenId];
        loan.weight += amount;
    }

    /**
     * @dev Internal function to get the locked amount for a specific loan.
     * @param tokenId The ID of the loan (NFT) for which the locked amount is being retrieved.
     * @return The locked amount for the specified loan.
     */
    function _getLockedAmount(
        uint256 tokenId
    ) internal view override returns (uint256) {
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(address(_ve)).locked(tokenId);
        if (
            !lockedBalance.isPermanent && lockedBalance.end < ProtocolTimeLibrary.epochStart(block.timestamp)
        ) {
            return 0;
        }
        require(lockedBalance.amount >= 0);
        // get the balance of veBlack
        uint256 veBlackBalance = IVotingEscrow(address(_ve)).balanceOfNFT(tokenId);
        // if the veBlack balance is greater than the locked balance, return the veBlack balance
        // the balance may be bigger because of super massive boost
        if(veBlackBalance > uint256(uint128(lockedBalance.amount))) {
            return veBlackBalance;
        }
        return uint256(uint128(lockedBalance.amount));
    }

    /**
     * @notice Resets the vote for a specific loan.
     * @param tokenId The ID of the loan (NFT) for which the vote is being reset.
     */
    function reset(uint256 tokenId) public  {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender);
        require(loan.balance == 0);
        loan.voteTimestamp = 0;
        IVoter(address(_voter)).reset(tokenId);
    }

    /**
     * @notice Returns the address of the ODOS Router contract.
     * @dev This function is used to interact with the ODOS Router for trading and swapping tokens.
     * @return The address of the ODOS Router contract.
     */
    function odosRouter() public override pure returns (address) {
        return 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05; // ODOS Router address
    }


    function setApprovedPools(address[] calldata pools, bool enable) public override virtual onlyOwner {
        for (uint256 i = 0; i < pools.length; i++) {
            // confirm pool is a valid gauge
            if (enable) require(_gaugeManager.isGaugeAliveForPool(pools[i]));
            _approvedPools[pools[i]] = enable;
        }
    }

    function claimRebase(uint256 tokenId) public {
        _claimRebase(_loanDetails[tokenId]);
    }


    function _claimRebase(LoanInfo storage loan) override internal {
        // claim from both rewards distributors
        address[] memory rewardsDistributors = new address[](2);
        rewardsDistributors[0] = address(_rewardsDistributor);
        rewardsDistributors[1] = address(0x7c7BD86BaF240dB3DbCc3f7a22B35c5bAa83bA28);
        for (uint256 i = 0; i < rewardsDistributors.length; i++) {
            uint256 claimable =  IRewardsDistributor(rewardsDistributors[i]).claimable(loan.tokenId);
            if (claimable > 0) {
                IRewardsDistributor(rewardsDistributors[i]).claim(loan.tokenId);
                addTotalWeight(claimable);
                loan.weight += claimable;
            }
        }
    }
    /**
     * @notice Processes rewards for a specific loan.
     * @dev This function handles the claiming and processing of rewards.
     * @param fees An array of addresses representing the fee recipients.
     * @param tokens An array of arrays of addresses representing the tokens to claim.
     * @param tokenId The ID of the loan (NFT) for which rewards are being processed.
     * @param tradeData The trade data for swapping tokens.
     */
    function _processRewards(
        address[] calldata fees,
        address[][] calldata tokens,
        uint256 tokenId,
        bytes calldata tradeData
    ) virtual internal override {
        _gaugeManager.claimBribes(fees, tokens, tokenId);
        ISwapper swapper = ISwapper(getSwapper());
        address[] memory flattenedTokens = swapper.flattenToken(tokens);

        if (tradeData.length == 0) {
            revert(); // No trade data provided, cannot proceed with claiming rewards
        }
        // get balance before claiming rewards
        // loop through flattened tokens and set allowances
        for (uint256 i = 0; i < flattenedTokens.length; i++) {
            IERC20 token = IERC20(flattenedTokens[i]);
            if (token.allowance(address(this), odosRouter()) < type(uint256).max) {
                token.approve(odosRouter(), type(uint256).max);
            }
        }

        (bool success,) = odosRouter().call{value: 0}(tradeData);
        require(success);


        for (uint256 i = 0; i < flattenedTokens.length; i++) {
            IERC20 token = IERC20(flattenedTokens[i]);
            if (token.allowance(address(this), odosRouter()) != 0) {
                token.approve(odosRouter(), 0);
            }
        }
    }
}