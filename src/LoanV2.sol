// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "./interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {ICLGauge} from "./interfaces/ICLGauge.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {RateStorage} from "./RateStorage.sol";
import {LoanStorage} from "./LoanStorage.sol";
import {IAerodromeRouter} from "./interfaces/IAerodromeRouter.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";

contract Loan is ReentrancyGuard, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, RateStorage, LoanStorage {
    // initial contract parameters are listed here
    // parametees introduced after initial deployment are in NamedStorage contracts
    IVoter internal _voter;
    IRewardsDistributor internal _rewardsDistributor;
    address private _pool; // deprecated
    IERC20 internal _usdc;
    IERC20 internal _aero;
    IVotingEscrow internal _ve;
    IAerodromeRouter internal _aeroRouter;
    address internal _aeroFactory;
    address internal _rateCalculator; // deprecated
    address public _vault;

    bool internal _paused;
    uint256 public _outstandingCapital;
    uint256 public  _multiplier; // rewards rate multiplier

    mapping(uint256 => LoanInfo) public _loanDetails;
    mapping(address => bool) public _approvedPools;

    mapping(uint256 => uint256) public _rewardsPerEpoch;
    uint256 private _lastEpochPaid; // deprecated

    
    // ZeroBalanceOption enum to handle different scenarios when the loan balance is zero
    enum ZeroBalanceOption {
        DoNothing, // do nothing when the balance is zero
        InvestToVault, // invest the balance to the vault
        PayToOwner // pay the balance to the owner
    }

    // LoanInfo struct to store details about each loan
    struct LoanInfo {
        uint256 tokenId;
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
        ZeroBalanceOption zeroBalanceOption;
        address[] pools; // deprecated
        uint256 voteTimestamp;
        uint256 claimTimestamp;
        uint256 weight;
        uint256 unpaidFees; // unpaid fees for the loan
        address preferredToken; // preferred token to receive for zero balance option
        uint256 increasePercentage; // Percentage of the rewards to increase each lock
        bool    topUp; // automatically tops up loan balance after rewards are claimed
    }

    // Pools each token votes on for this epoch
    address[] public _defaultPools;
    // Weights for each pool (must equal length of _defaultPools)
    uint256[] public _defaultWeights;
    // Time when the default pools were last changed
    uint256 public _defaultPoolChangeTime;

    
    /**
     * @dev Emitted when collateral is added to a loan.
     * @param tokenId The ID of the token representing the loan.
     * @param owner The address of the owner adding the collateral.
     * @param option The zero balance option chosen for the loan.
     */
    
    event CollateralAdded(uint256 tokenId, address owner, ZeroBalanceOption option);

    /**
     * @dev Emitted when collateral is withdrawn from a loan.
     * @param tokenId The ID of the token representing the loan.
     * @param owner The address of the owner withdrawing the collateral.
     */
    event CollateralWithdrawn(uint256 tokenId, address owner);
    
    /**
     * @dev Emitted when funds are borrowed against a loan.
     * @param tokenId The ID of the token representing the loan.
     * @param owner The address of the borrower.
     * @param amount The amount of funds borrowed.
     */
    event FundsBorrowed(uint256 tokenId, address owner, uint256 amount);
    
    /**
     * @dev Emitted when rewards are received for a loan.
     * @param epoch The epoch during which the rewards were received.
     * @param amount The amount of rewards received.
     * @param borrower The address of the borrower receiving the rewards.
     * @param tokenId The ID of the token representing the loan.
     */
    
    event RewardsReceived(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    /**
     * @dev mitted when rewards are sent to the vault to lenders as a premium.
     * @param tokenId The ID of the token representing the loan.
     * @param borrower The address of the borrower repaying the loan.
     * @param amount The amount repaid.
     * @param epoch The epoch during which the repayment occurred.
     * @param isManual Indicates whether the repayment was manual.
     */
    
    event LoanPaid(uint256 tokenId, address borrower, uint256 amount, uint256 epoch, bool isManual);
    /**
     * @dev Emitted when rewards are invested back into the vault.
     * @param epoch The epoch during which the rewards were invested.
     * @param amount The amount of rewards invested.
     * @param borrower The address of the borrower whose rewards were invested.
     * @param tokenId The ID of the token representing the loan.
     */
    event RewardsInvested(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    
    /**
     * @dev Total Rewards (Fees/Bribes) Claimed for a token.
     * @param epoch The epoch during which the rewards were claimed.
     * @param amount The amount of rewards claimed.
     * @param borrower The address of the borrower claiming the rewards.
     * @param tokenId The ID of the token representing the loan.
     */
    
    event RewardsClaimed(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    /**
     * @dev Emitted when rewards are paid to the owner of the loan.
     * @param epoch The epoch during which the rewards were paid.
     * @param amount The amount of rewards paid.
     * @param borrower The address of the borrower associated with the loan.
     * @param tokenId The ID of the token representing the loan.
     */
    event RewardsPaidtoOwner(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    
    /**
     * @dev Emitted when the protocol fee is paid.
     * @param epoch The epoch during which the fee was paid.
     * @param amount The amount of the protocol fee paid.
     * @param borrower The address of the borrower paying the fee.
     * @param tokenId The ID of the token representing the loan.
     */
    
    event ProtocolFeePaid(uint256 epoch, uint256 amount, address borrower, uint256 tokenId, address token);
    /**
     * @dev Emitted when a user's veNFT balance is increased.
     * @param user The address of the user whose veNFT balance is increased.
     * @param tokenId The ID of the veNFT token.
     * @param amount The amount by which the veNFT balance is increased.
     */
    event VeNftIncreased(uint256 epoch, address indexed user, uint256 indexed tokenId, uint256 amount);

    /** ERROR CODES */
    // error TokenNotLocked();
    // error TokenLockExpired(uint256 tokenId);
    // error InvalidLoanAmount();
    // error PriceNotConfirmed();
    // error LoanNotFound(uint256 tokenId);
    // error NotOwnerOfToken(uint256 tokenId, address owner);
    // error LoanActive(uint256 tokenId);

    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


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
        bool topUp
    ) public  {
        require(confirmUsdcPrice());
        // require the msg.sender to be the owner of the token
        require(_ve.ownerOf(tokenId) == msg.sender);

        // ensure the token is locked permanently
        IVotingEscrow.LockedBalance memory lockedBalance = _ve.locked(tokenId);
        if (!lockedBalance.isPermanent) {
            require(lockedBalance.end > block.timestamp);
            _ve.lockPermanent(tokenId);
        }

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
            preferredToken: address(0),
            increasePercentage: increasePercentage,
            topUp: topUp
        });

        vote(tokenId);

        // transfer the token to the contract
        _ve.transferFrom(msg.sender, address(this), tokenId);
        require(_ve.ownerOf(tokenId) == address(this));
        emit CollateralAdded(tokenId, msg.sender, zeroBalanceOption);


        require(increasePercentage <= 10000);
        if(preferredToken != address(0)) {
            require(isApprovedToken(preferredToken));
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

    /**
     * @dev Increases the loan amount for a given tokenId by a specified amount.
     *      The function checks if the token is locked, if the amount is valid,
     *      and if the borrower is the one requesting the increase.
     * @param tokenId The ID of the loan for which the amount is being increased.
     * @param amount The amount to increase the loan by. Must be greater than .01 USDC.
     */
    function increaseLoan(
        uint256 tokenId,
        uint256 amount
    ) public  {
        require(amount > .01e6);
        require(_ve.ownerOf(tokenId) == address(this));
        require(confirmUsdcPrice());
        LoanInfo storage loan = _loanDetails[tokenId];

        require(loan.borrower == msg.sender);
        _increaseLoan(loan, tokenId, amount);

       // set a default payoff token if not set
       if(getUserPayoffToken(loan.borrower) == 0) {
           _setUserPayoffToken(loan.borrower, tokenId);
       }
    }


    /**
     * @dev Increases the loan amount for a given tokenId by a specified amount.
     *      The function checks if the token is locked, if the amount is valid,
     *      and if the borrower is the one requesting the increase.
     * @param tokenId The ID of the loan for which the amount is being increased.
     * @param amount The amount to increase the loan by. Must be greater than .01 USDC.
     */
    function _increaseLoan(LoanInfo storage loan, uint256 tokenId, uint256 amount) internal {
        (uint256 maxLoan, ) = getMaxLoan(tokenId);
        require(amount <= maxLoan);
        uint256 originationFee = (amount * 80) / 10000; // 0.8%
        loan.unpaidFees += originationFee;
        loan.balance += amount + originationFee;
        loan.outstandingCapital += amount;
        _outstandingCapital += amount;
        _usdc.transferFrom(_vault, msg.sender, amount);
        emit FundsBorrowed(tokenId, loan.borrower, amount);
    }

    /**
     * @dev Claims rewards for a given loan and swaps them to the asset (USDC or Aero/Velo).
     *      The function calculates the total rewards claimed and returns it.
     * @param tokenId The ID of the loan for which rewards are being claimed.
     * @param fees An array of addresses representing the fee tokens to be claimed.
     * @param tokens A two-dimensional array of addresses representing the tokens to be swapped to the asset.
     * @return totalRewards The total amount of rewards claimed and swapped to the asset.
     */
    function _getRewards(uint256 tokenId, address[] memory fees, address[][] memory tokens) internal returns (uint256 totalRewards) {
        LoanInfo storage loan = _loanDetails[tokenId];
        IERC20 asset = _getAsset(loan);
        uint256 assetBalancePre = asset.balanceOf(address(this));

        ISwapper swapper = ISwapper(getSwapper());
        address[] memory flattenedTokens = swapper.flattenToken(tokens);
        uint256[] memory tokenBalances = swapper.getTokenBalances(flattenedTokens);
        _voter.claimFees(fees, tokens, tokenId);
        _swapTokensToAsset(flattenedTokens, asset, loan.borrower, tokenBalances);
        uint256 assetBalancePost = asset.balanceOf(address(this));

        // calculate the amount of fees claimed
        return assetBalancePost - assetBalancePre;
    }

    /**
     * @dev Returns the asset (either USDC or Aero/Velo) based on the loan's balance and zeroBalanceOption.
     * @param loan The LoanInfo struct containing the loan details.
     * @return The IERC20 asset to be used for the loan.
     */
    function _getAsset(LoanInfo storage loan) internal view returns (IERC20) {
        if(loan.balance > 0) {
            return _usdc;
        }
        if(loan.zeroBalanceOption == ZeroBalanceOption.PayToOwner && loan.preferredToken != address(0)) {
            return IERC20(loan.preferredToken);
        }
        
        return _usdc;
    }


    /**
     * @dev Swaps all tokens in the provided array to a specified asset and transfers the resulting asset to the borrower.
     * @param totalTokens An array of token addresses to be swapped.
     * @param asset The target asset to which the tokens will be swapped.
     * @param borrower The address of the borrower to receive the swapped asset.
     */
    function _swapTokensToAsset(
        address[] memory totalTokens,
        IERC20 asset,
        address borrower,
        uint256[] memory balanceBefore
    ) internal {
        for (uint256 i = 0; i < totalTokens.length; i++) {
            uint256 tokenBalance = IERC20(totalTokens[i]).balanceOf(address(this));
            if (tokenBalance <= balanceBefore[i]) {
                continue;
            }
            if (tokenBalance > 0) {
                _swapToToken(tokenBalance - balanceBefore[i], totalTokens[i], address(asset), borrower);
            }
        }
    }


    /**
     * @dev Checks if tokens has vote this epoch
    * @param tokenId The ID of the token to check.
    * @return True if the token can vote on the pool, false otherwise.
     */
    function canVoteOnPool(uint256 tokenId) internal virtual view returns (bool) {
        return _voter.lastVoted(tokenId) < currentEpochStart() && _withinVotingWindow();
    }
    
    /**
     * @dev Internal function to swap a specified amount of one token to another token.
     *      If the `fromToken` and `toToken` are the same or the `amountIn` is zero, 
     *      the function returns the input amount without performing any swap.
     * 
     * @param amountIn The amount of the `fromToken` to be swapped.
     * @param fromToken The address of the token to be swapped from.
     * @param toToken The address of the token to be swapped to.
     * @param borrower The address of the borrower to send the tokens to if the swap fails.
     * 
     * @return amountOut The amount of the `toToken` received after the swap.
     * 
     * Requirements:
     * - The `fromToken` must be approved for spending by the `_aeroRouter`.
     * - The `_aeroRouter` and `_aeroFactory` must be properly configured.
     * 
     * Behavior:
     * - If the swap route returns zero output, the `fromToken` is transferred back to the borrower.
     * - Otherwise, the function performs the token swap using the `_aeroRouter` and returns the amount received.
     */

    function _swapToToken(
        uint256 amountIn,
        address fromToken,
        address toToken,
        address borrower
    ) internal returns (uint256 amountOut) {
        require(fromToken != address(_ve)); // Prevent swapping veNFT
        if (fromToken == toToken || amountIn == 0) {
            return amountIn;
        }
        IERC20(fromToken).approve(address(_aeroRouter), 0); // reset approval first
        IERC20(fromToken).approve(address(_aeroRouter), amountIn);
        ISwapper swapper = ISwapper(getSwapper());
        IRouter.Route[] memory routes = ISwapper(swapper).getBestRoute(fromToken, toToken, amountIn);
        uint256 minimumAmountOut = ISwapper(swapper).getMinimumAmountOut(routes, amountIn);
        
        if (minimumAmountOut == 0) {
            // send to borrower if the swap returns 0
            IERC20(fromToken).transfer(borrower, amountIn);
            return 0;
        }
        uint256[] memory amounts = _aeroRouter.swapExactTokensForTokens(
                amountIn,
                minimumAmountOut,
                routes,
                address(this),
                block.timestamp
            );
        return amounts[0];
    }

    /**
     * @notice Allows a borrower to make a payment towards their loan.
     * @dev If the `amount` parameter is set to 0, the entire remaining loan balance will be paid.
     *      The function transfers the specified `amount` of USDC from the caller to the contract
     *      and then processes the payment.
     * @param tokenId The unique identifier of the loan.
     * @param amount The amount of USDC to pay. If set to 0, the full loan balance will be paid.
     */
    function pay(uint256 tokenId, uint256 amount) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        if (amount == 0) {
            amount = loan.balance;
        }

        _usdc.transferFrom(msg.sender, address(this), amount);
        _pay(tokenId, amount, true);
    }

    /**
     * @dev Allows the borrower to pay off their loan in multiple transactions.
     *      This function iterates through an array of token IDs and calls the pay function for each one.
     * 
     * @param tokenIds An array of token IDs representing the loans to be paid off.
     */
    function payMultiple(uint256[] memory tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            pay(tokenIds[i], 0);
        }
    }


    /**
     * @dev Internal function to handle loan payments. This function processes the payment amount,
     *      deducts any unpaid fees, updates the loan balance, and transfers the payment to the vault.
     *      If there is an excess payment, it is handled separately.
     * 
     * @param tokenId The unique identifier of the loan being paid.
     * @param amount The amount being paid towards the loan.
     */
    function _pay(uint256 tokenId, uint256 amount, bool isManual) internal {
        if (amount == 0) {
            return;
        }
        LoanInfo storage loan = _loanDetails[tokenId];

        // take out unpaid fees first
        if(loan.unpaidFees > 0) {
            uint256 feesPaid = loan.unpaidFees;
            if(feesPaid > amount) {
                feesPaid = amount;
            }
            amount -= feesPaid;
            loan.unpaidFees -= feesPaid;
            loan.balance -= feesPaid;
            _usdc.transfer(owner(), feesPaid);
            emit LoanPaid(tokenId, loan.borrower, feesPaid, currentEpochStart(), isManual);
            emit ProtocolFeePaid(currentEpochStart(), feesPaid, loan.borrower, tokenId, address(_usdc));
            if(amount == 0) {
                return;
            }
        }

        uint256 payoffToken = getUserPayoffToken(loan.borrower);
        // process the payment
        uint256 excess = 0;
        if (amount >= loan.balance) {
            excess = amount - loan.balance;
            amount = loan.balance;
            if(payoffToken == tokenId) {
                _setUserPayoffToken(loan.borrower, 0); // reset the payoff token if the loan is fully paid
            }
        }
        loan.balance -= amount;
        if (amount > loan.outstandingCapital) {
            _outstandingCapital -= loan.outstandingCapital;
            loan.outstandingCapital = 0;
        } else {
            loan.outstandingCapital -= amount;
            _outstandingCapital -= amount;
        }

        _usdc.transfer(_vault, amount);
        emit LoanPaid(tokenId, loan.borrower, amount, currentEpochStart(), isManual);
        // if there is an excess payment, handle it according to the zero balance option
        if (excess > 0) {
            _handleZeroBalance(tokenId, excess, true);
        }

        if(!isManual && loan.topUp) {
            (uint256 maxLoan, ) = getMaxLoan(tokenId);
            _increaseLoan(loan, tokenId, maxLoan);
        }


        // set default payoff token if none set
       if(payoffToken == 0 && loan.balance > 0) {
           _setUserPayoffToken(loan.borrower, tokenId);
       }
    }


    function _handlePayoffToken(address borrower, uint256 tokenId, uint256 amount) internal returns (uint256) {
       uint256 payoffToken = getUserPayoffToken(borrower);

       if(payoffToken == 0 || !userUsesPayoffToken(borrower) || payoffToken == tokenId) {
            // no payoff token set, or the payoff token is the same as the current tokenId
           return 0;
       }

        LoanInfo memory payoffLoan = _loanDetails[payoffToken];
        if(payoffLoan.borrower != borrower) {
            return 0; // not the borrower of the payoff loan
        }
        uint256 payoffAmount = amount;
        if(payoffAmount >= payoffLoan.balance) {
            payoffAmount = payoffLoan.balance; // cap the payment to the balance of the loan
        }
        _pay(payoffToken, payoffAmount, false);
        return payoffAmount;
    }
    /**
     * @dev Claims rebase rewards for a given loan and updates its weight.
     *
     * @param loan The LoanInfo struct representing the loan for which rebase
     *             rewards are being claimed.
     *
     * Requirements:
     * - The `_rewardsDistributor` must provide a valid claimable amount for the
     *   loan's token ID.
     * - The `_rewardsDistributor.claim` function must not revert.
     *
     * Note:
     * - If the `_rewardsDistributor.claim` function fails, the function will
     *   silently catch the error and return without making any changes.
     */
    function _claimRebase(LoanInfo storage loan) internal {
        uint256 claimable = _rewardsDistributor.claimable(loan.tokenId);
        if (claimable > 0) {
            try _rewardsDistributor.claim(loan.tokenId) {
                addTotalWeight(claimable);
                loan.weight += claimable;
            } catch {
            }
        }
    }

    /**
     * @notice Transfers a specified amount of USDC from the caller to the vault and records the rewards.
     * @dev This function requires the caller to have approved the contract to transfer the specified amount of USDC.
     * @param amount The amount of USDC to transfer to the vault and record as rewards.
     */
    function incentivizeVault(uint256 amount) public {
        _usdc.transferFrom(msg.sender, _vault, amount);
        recordRewards(amount, msg.sender, type(uint256).max);
    }
    
    /**
     * @dev Handles the distribution of rewards or balances based on the zero balance option set for a loan.
     *      This function is internal and is used to process rewards or balances when a loan reaches a zero balance.
     * @param tokenId The ID of the loan token.
     * @param amount The amount to be processed.
     * @param wasActiveLoan A boolean indicating whether the loan had a balance when rewards were claimed originally.
     *
     * The function supports the following zero balance options:
     * - `InvestToVault`: Invests the amount into a vault on behalf of the borrower.
     * - `PayToOwner`: Pays the amount to the borrower.
     * - `DoNothing`: Transfers the amount to the borrower without any additional processing.
     */
    function _handleZeroBalance(uint256 tokenId, uint256 amount, bool wasActiveLoan) internal {
        LoanInfo storage loan = _loanDetails[tokenId];
        IERC20 asset = wasActiveLoan ? IERC20(_usdc) : _getAsset(loan);
        amount -= _payZeroBalanceFee(loan.borrower, tokenId, amount, address(asset));
        // InvestToVault: invest the amount to the vault on behalf of the borrower
        // In the rare event a user may be blacklisted from  USDC, we invest to vault directly for the borrower to avoid any issues.
        // The user may withdraw their investment later if they are unblacklisted.
        if (loan.zeroBalanceOption == ZeroBalanceOption.InvestToVault || wasActiveLoan) {
            _usdc.approve(_vault, amount);
            IERC4626(_vault).deposit(amount, loan.borrower);
            emit RewardsInvested(currentEpochStart(), amount, loan.borrower, tokenId);
            return;
        }
        // If PayToOwner or DoNothing, send tokens to the borrower and pay applicable fees
        require(asset.transfer(loan.borrower, amount));
        emit RewardsPaidtoOwner(currentEpochStart(), amount, loan.borrower, tokenId);
        return;
    }


    /**
     * @dev Handles the payment of zero balance fees for a given loan.
     * @param borrower The address of the borrower.
     * @param tokenId The ID of the loan token.
     * @param amount The amount to be paid.
     * @param token The address of the token being used for payment.
     * @return fee The amount of the zero balance fee paid.
     */
    function _payZeroBalanceFee(address borrower, uint256 tokenId, uint256 amount, address token) internal returns (uint256) {
        uint256 zeroBalanceFee = (amount * getZeroBalanceFee()) / 10000;
        IERC20(token).transfer(owner(), zeroBalanceFee);
        emit ProtocolFeePaid(currentEpochStart(), zeroBalanceFee, borrower, tokenId, address(token));
        return zeroBalanceFee;
    }

    /**
     * @notice Claims rewards for a specific loan and handles the distribution of rewards.
     * @dev This function retrieves rewards for the given token ID, calculates protocol fees,
     *      lender premiums, and handles zero balance scenarios based on the loan's configuration.
     * @param tokenId The ID of the loan (NFT) for which rewards are being claimed.
     * @param fees An array of addresses representing the fee tokens to be claimed.
     * @param tokens A two-dimensional array of addresses representing the tokens to be swapped to the asset.
     * @return totalRewards The total amount usdc claimed after fees.
     */
    function claim(uint256 tokenId, address[] calldata fees, address[][] calldata tokens) public returns (uint256 totalRewards) {
        LoanInfo storage loan = _loanDetails[tokenId];

        // If the loan has no borrower or the token is not locked in the contract, exit early.
        if (loan.borrower == address(0) || _ve.ownerOf(tokenId) != address(this)) {
            return 0;
        }

        // If the loan balance is zero and the zero balance option is set to DoNothing, exit early.
        if (loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.DoNothing) {
            return 0;
        }

        // Retrieve rewards for the loan.
        totalRewards = _getRewards(tokenId, fees, tokens);
        uint256 amount = totalRewards;

        // If no rewards were retrieved, exit early.
        if (amount == 0) {
            return 0;
        }

        // Emit an event indicating that rewards have been claimed.
        emit RewardsClaimed(currentEpochStart(), amount, loan.borrower, tokenId);

         // If the loan balance is zero and the user is not using a payoff token, handle zero balance scenarios.
        if(loan.balance == 0 && !userUsesPayoffToken(loan.borrower)) {
            uint256 amountAfterFees = amount - _increaseNft(loan, amount, true);
            _handleZeroBalance(tokenId, amountAfterFees, false);
            _claimRebase(loan);
            return totalRewards;
        }

        uint256 feeEligibleAmount = amount;
        if(amount > loan.balance) {
            feeEligibleAmount = loan.balance;
        }

        // Calculate the protocol fee based on the rewards amount.
        uint256 protocolFee = (feeEligibleAmount * getProtocolFee()) / 10000;
        // Transfer the protocol fee to the contract owner.
        _usdc.transfer(owner(), protocolFee);
        emit ProtocolFeePaid(currentEpochStart(), protocolFee, loan.borrower, tokenId, address(_usdc));

        // Calculate the lender premium based on the rewards amount.
        uint256 lenderPremium = (feeEligibleAmount * getLenderPremium()) / 10000;

        // Transfer the lender premium to the vault.
        _usdc.transfer(_vault, lenderPremium);
        recordRewards(lenderPremium, loan.borrower, tokenId);
        
        // if user has an increase percentage set, increase the veNFT amount
        uint256 remaining = amount - protocolFee - lenderPremium - _increaseNft(loan, amount, false);

        remaining -= _handlePayoffToken(loan.borrower, tokenId, remaining);
        _pay(tokenId, remaining, false);
        _claimRebase(loan);
        require(_ve.ownerOf(tokenId) == address(this));
    }
    
    /**
     * @dev Internal function to increase the NFT-related value for a loan.
     * @param loan The LoanInfo struct containing details of the loan.
     * @param claimedRewards The amount of rewards that have been claimed.
     * @return spent The amount spent to increase the veNFT balance, or 0 if no increase is made.
     */
    function _increaseNft(LoanInfo memory loan, uint256 claimedRewards, bool takeFees) internal  returns (uint256 spent) {
        if(loan.increasePercentage == 0) {
            return 0; // No increase
        }
        uint256 increasePercentage = loan.increasePercentage;
        if(loan.balance > 0 && loan.increasePercentage > 2500) {
            increasePercentage = 2500; // Cap the increase percentage to 25% max
        }
        uint256 amountToIncrease = (claimedRewards * increasePercentage) / 10000;

        uint256 amountOut = _swapToToken(amountToIncrease, address(_usdc), address(_aero), loan.borrower);

        // get protocol fee 
        if(takeFees) {
            amountOut -= _payZeroBalanceFee(loan.borrower, loan.tokenId, amountOut, address(_aero));
        }

        _aero.approve(address(_ve), amountOut);
        _ve.increaseAmount(loan.tokenId, amountOut);
        emit VeNftIncreased(currentEpochStart(), loan.borrower, loan.tokenId, amountOut);
        addTotalWeight(amountOut);
        return amountToIncrease;
    }

    /**
     * @notice Increases the locked amount of a veNFT token.
     * @dev This function locks tokens into the veNFT associated with the given token ID.
     * @param tokenId The ID of the veNFT whose amount is to be increased.
     * @param amount The amount of tokens to be added to the veNFT.
     */

    function increaseAmount(uint256 tokenId, uint256 amount) public {
        require(_ve.ownerOf(tokenId) == address(this));
        require(amount > 0);
        require(_aero.transferFrom(msg.sender, address(this), amount));
        _aero.approve(address(_ve), amount);
        _ve.increaseAmount(tokenId, amount);
        emit VeNftIncreased(currentEpochStart(), msg.sender, tokenId, amount);
        addTotalWeight(amount);
    }


    /**
     * @notice Allows the borrower to vote on the default pools for their loan.
     * @dev This function can only be called on the last day of the epoch.
     *      It updates the vote timestamp and calls the internal _vote function.
     * @param tokenId The ID of the loan (NFT) for which the vote is being cast.
     */
    function vote(uint256 tokenId) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        if(canVoteOnPool(tokenId)) {
            (address[] memory pools, uint256[] memory weights, uint256 changeTime) = getUserPoolVotes(loan.borrower);
            if(pools.length == 0) {
                pools = _defaultPools;
                weights = _defaultWeights;
                changeTime = _defaultPoolChangeTime;
            }
            if(loan.voteTimestamp < changeTime) {
                try _voter.vote(tokenId, pools, weights) {
                    loan.voteTimestamp = block.timestamp;
                    return;
                } catch { }
            }
        } 
        try _voter.poke(tokenId) { 
        } catch { }
    }

    /**
     * @notice Allows the borrower to claim their collateral (veNFT) after the loan is fully repaid.
     * @dev This function ensures that only the borrower can claim the collateral and that the loan is fully repaid.
     *      If the loan balance is greater than zero, the collateral cannot be claimed.
     * @param tokenId The ID of the loan (NFT) whose collateral is being claimed.
     */
    function claimCollateral(uint256 tokenId) public {
        LoanInfo storage loan = _loanDetails[tokenId];

        // Ensure that the caller is the borrower of the loan
        require(loan.borrower == msg.sender);

        // Ensure that the loan is fully repaid before allowing collateral to be claimed
        require(loan.balance == 0);

        _ve.transferFrom(address(this), loan.borrower, tokenId);
        emit CollateralWithdrawn(tokenId, msg.sender);
        subTotalWeight(loan.weight);
        delete _loanDetails[tokenId];
    }

    /**
     * @notice Calculates the maximum loan amount that can be borrowed for a given token ID.
     * @dev This function considers the veNFT balance, rewards rate, vault utilization, and current loan balance.
     * @param tokenId The ID of the loan (NFT).
     * @return maxLoan The maximum loan amount that can be borrowed.
     * @return maxLoanIgnoreSupply The maximum loan amount ignoring vault supply constraints.
     */
    function getMaxLoan(
        uint256 tokenId
    ) public view returns (uint256, uint256) {
        // Calculate the veNFT balance of the token at the current block timestamp
        uint256 veBalance = _ve.balanceOfNFTAt(tokenId, block.timestamp);

        uint256 rewardsRate = getRewardsRate();

        // Calculate the maximum loan ignoring vault supply constraints
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) *
            _multiplier) / 1e12; // rewardsRate * veNFT balance of token
        uint256 maxLoan = maxLoanIgnoreSupply * 10000 / (10000 + 80);
        
        // Calculate the maximum utilization ratio (80% of the vault supply)
        uint256 vaultBalance = _usdc.balanceOf(_vault);
        uint256 vaultSupply = vaultBalance + _outstandingCapital;
        uint256 maxUtilization = (vaultSupply * 8000) / 10000;

        // If the vault is over-utilized, no loans can be made
        if (_outstandingCapital > maxUtilization) {
            return (0, maxLoanIgnoreSupply);
        }

        LoanInfo storage loan = _loanDetails[tokenId];

        // If the current loan balance exceeds the maximum loan, no additional loans can be made
        if (loan.balance > maxLoan) {
            return (0, maxLoanIgnoreSupply);
        }

        // Subtract the current loan balance from the maximum loan
        maxLoan = maxLoan - loan.balance;

        // Ensure the loan amount does not exceed the available vault supply
        uint256 vaultAvailableSupply = maxUtilization - _outstandingCapital;
        if (maxLoan > vaultAvailableSupply) {
            maxLoan = vaultAvailableSupply;
        }

        // Ensure the loan amount does not exceed the vault's current balance
        if (maxLoan > vaultBalance) {
            maxLoan = vaultBalance;
        }

        return (maxLoan, maxLoanIgnoreSupply);
    }
    
    /**
     * @notice Records the rewards for the current epoch.
     * @dev This function adds the specified rewards to the total rewards for the current epoch.
     * @param rewards The amount of rewards to record.
     */
    function recordRewards(uint256 rewards, address borrower, uint256 tokenId) internal {
        _rewardsPerEpoch[currentEpochStart()] += rewards;
        emit RewardsReceived(currentEpochStart(), rewards, borrower, tokenId);
    }

    /* Rate Methods */

    /**
     * @notice Retrieves the zero balance fee percentage.
     * @dev This function checks the zero balance fee stored in the RateStorage contract.
     *      If the zero balance fee is not set (returns 0), it defaults to 1%.
     * @return The zero balance fee percentage (in basis points, where 100 = 1%).
     */
    function getZeroBalanceFee() public view override returns (uint256) {
        uint256 zeroBalanceFee = RateStorage.getZeroBalanceFee();
        return zeroBalanceFee;
    }


    /**
     * @notice Retrieves the rewards rate for the current epoch.
     * @dev This function checks the rewards rate stored in the RateStorage contract.
     *      If the rewards rate is not set (returns 0), it defaults to 113 (11.3%).
     * @return The rewards rate percentage (in basis points, where 113 = 1.13%).
     */
    function getRewardsRate() public view override returns (uint256) {
        uint256 rewardsRate = RateStorage.getRewardsRate();
        return rewardsRate;
    }

    /**
     * @notice Retrieves the lender premium percentage.
     * @dev This function checks the lender premium stored in the RateStorage contract.
     *      If the lender premium is not set (returns 0), it defaults to 20%.
     * @return The lender premium percentage (in basis points, where 2000 = 20%).
     */
    function getLenderPremium() public view override returns (uint256) {
        uint256 lenderPremium = RateStorage.getLenderPremium();
        return lenderPremium;
    }

    /**
     * @notice Retrieves the protocol fee percentage.
     * @dev This function checks the protocol fee stored in the RateStorage contract.
     *      If the protocol fee is not set (returns 0), it defaults to 5%.
     * @return The protocol fee percentage (in basis points, where 500 = 5%).
     */
    function getProtocolFee() public view override returns (uint256) {
        uint256 protocolFee = RateStorage.getProtocolFee();
        return protocolFee;
    }


    /* VIEW FUNCTIONS */

    /**
     * @notice Retrieves the loan details for a specific token ID.
     * @dev This function returns the balance, borrower address, and pools associated with the loan.
     * @param tokenId The ID of the loan (NFT).
     * @return balance The current balance of the loan.
     * @return borrower The address of the borrower.
     */
    function getLoanDetails(
        uint256 tokenId
    ) public view returns (uint256 balance, address borrower) {
        LoanInfo storage loan = _loanDetails[tokenId];
        return (loan.balance, loan.borrower);
    }

    /**
     * @notice Retrieves the total amount of active assets (outstanding capital).
     * @dev This function returns the value of `_outstandingCapital`, which represents the total active loans.
     * @return The total amount of active assets.
     */
    function activeAssets() public view returns (uint256) {
        return _outstandingCapital;
    }


    /**
     * @notice Retrieves the rewards for the current epoch.
     * @dev This function returns the total rewards recorded for the current epoch.
     * @return The total rewards for the current epoch.
     */
    function lastEpochReward() public view returns (uint256) {
        return _rewardsPerEpoch[currentEpochStart()];
    }

    /* OWNER METHODS */

    /**
     * @notice Allows the owner to merge the managed NFT with a specified token ID.
     * @dev This function can only be called by the owner of the contract.
     *      Note: This should only be possible for Flight School rewards sent to the contract.
     * @param tokenId The ID of the token to merge with the managed NFT.
     *
     * ManagedNFT is essentially a community owned veNFT where users can increase the NFT to obtain shares
     * In the future this can be used as collateral for loans
     */
    function mergeIntoManagedNft(uint256 tokenId) public onlyOwner {
        uint256 managedNft = getManagedNft();
        require(_ve.ownerOf(tokenId) == address(this));
        require(_ve.ownerOf(managedNft) == address(this));
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == address(0));
        uint256 beginningBalance = _ve.balanceOfNFTAt(managedNft, block.timestamp);
        _ve.merge(tokenId, managedNft);
        addTotalWeight(_ve.balanceOfNFTAt(managedNft, block.timestamp) - beginningBalance);
    }
    

    /**
     * @notice Allows user to merge their veNFT into another veNFT.
     * @dev This function can only be called by the owner of the veNFT being merged.
     * @param from The ID of the token to merge from.
     * @param to The ID of the token to merge to.
     */
    function merge(uint256 from, uint256 to) public {
        require(_ve.ownerOf(to) == address(this));
        require(_ve.ownerOf(from) == msg.sender);
        LoanInfo storage loan = _loanDetails[to];
        require(loan.borrower == msg.sender);
        uint256 beginningBalance = _ve.balanceOfNFTAt(to, block.timestamp);
        _ve.merge(from, to);
        addTotalWeight(_ve.balanceOfNFTAt(to, block.timestamp) - beginningBalance);
    }

    /**
     * @notice Sets the managed NFT for the contract
     * @dev Transfers the NFT from the sender to the contract, updates the managed NFT state
     * @param tokenId The ID of the NFT to be managed by the contract.
     */
    function setManagedNft(uint256 tokenId) public onlyOwner override {
        require(getManagedNft() == 0);
        super.setManagedNft(tokenId);
    }

    /**
     * @notice Allows the owner to set the default pools and their respective weights.
     * @dev The pools must have valid gauges, and the weights must sum up to 100e18 (100%).
     *      Updates the default pool change time to the current block timestamp.
     * @param pools An array of addresses representing the default pools.
     * @param weights An array of uint256 values representing the weights of the pools.
     */
    function setDefaultPools(
        address[] calldata pools,
        uint256[] calldata weights
    ) public onlyOwner {
        _validatePoolChoices(pools, weights);
        _defaultPools = pools;
        _defaultWeights = weights;
        _defaultPoolChangeTime = block.timestamp;
    }


    /**
     * @dev Validates the pool choices by checking the weights and approved pools.
     * @param pools An array of addresses representing the pools to be validated.
     * @param weights An array of uint256 values representing the weights of the pools.
     */
    function _validatePoolChoices(
        address[] memory pools,
        uint256[] memory weights
    ) internal view{
        require(pools.length == weights.length);
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            require(weights[i] > 0);
            require(_approvedPools[pools[i]]);
            totalWeight += weights[i];
        }
        require(totalWeight == 100e18);
    }
    /**
     * @notice Sets the multiplier value for the contract.
     * @dev This function can only be called by the owner of the contract.
     * @param multiplier The new multiplier value to be set.
     */
    function setMultiplier(uint256 multiplier) public onlyOwner {
        _multiplier = multiplier;
    }


    /**
     * @notice Sets the approved pools for the contract.
     * @dev This function can only be called by the owner of the contract.
     * @param pools An array of addresses representing the pools to be approved or disapproved.
     * @param enable A boolean indicating whether to approve or disapprove the pools.
     */
    function setApprovedPools(address[] calldata pools, bool enable) public onlyOwner {
        for (uint256 i = 0; i < pools.length; i++) {
            // confirm pool is a valid gauge
            address gauge = _voter.gauges(pools[i]);
            require(ICLGauge(gauge).isPool());
            _approvedPools[pools[i]] = enable;
        }
    }

    /**
     * @notice Overrides the renounceOwnership function to prevent the owner from renouncing ownership.
     */
    function renounceOwnership() public view override onlyOwner {
        revert();
    }

    /**
     * @notice Rescue any ERC20 tokens that are stuck in the contract.
     * @dev This function can only be called by the owner of the contract.
     * @param token The address of the ERC20 token to rescue.
     * @param amount The amount of tokens to rescue.
     */
    function rescueERC20(address token, uint256 amount) public onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /* USER METHODS */
    /**
     * @notice Sets the zero balance option for a specific loan.
     * @dev This function can only be called by the borrower of the loan.
     * @param tokenId The ID of the loan (NFT).
     * @param option The zero balance option to set.
     */
    function setZeroBalanceOption(
        uint256 tokenId,
        ZeroBalanceOption option
    ) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender);
        loan.zeroBalanceOption = option;
    }


    /**
     * @notice Sets the top-up option for a specific loan.
     * @dev This function can only be called by the borrower of the loan.
     * @param tokenId The ID of the loan (NFT).
     * @param enable A boolean indicating whether to enable or disable the top-up option.
     */
    function setTopUp(
        uint256 tokenId,
        bool enable
    ) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender);
        loan.topUp = enable;
    }

    /**
     * @notice Sets the preferred token for a specific loan.
     * @dev This function can only be called by the borrower of the loan.
     * @param tokenId The ID of the loan (NFT).
     * @param preferredToken The address of the preferred token to set.
     */
    function setPreferredToken(
        uint256 tokenId,
        address preferredToken
    ) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender);
        require(isApprovedToken(preferredToken));
        loan.preferredToken = preferredToken;
    }
    


    /**
     * @notice Allows the borrower to vote on preapproved pools for their loan.
     * @dev The number of pools is limited to 12, and the weights equal 100e18.
     *      The function validates the pool choices and sets the user's pool votes.
     *      To remove votes and return to default, send empty arrays.
     * @param pools An array of addresses representing the pools to vote for.
     * @param weights An array of uint256 values representing the weights of the pools.
     */
    function userVote(
        address[] calldata pools,
        uint256[] calldata weights
    ) public {
        require(pools.length < 12); // limit the number of pools to 12
        _validatePoolChoices(pools, weights);
        _setUserPoolVotes(msg.sender, pools, weights);
    }
    
    /**
     * @notice Sets the increase percentage for a specific loan.
     * @dev This function allows the borrower to set the increase percentage for their loan.
     *      The increase percentage must not exceed 25% (represented as 2500 basis points).
     * @param tokenId The unique identifier of the loan.
     * @param increasePercentage The new increase percentage to be set, in basis points (1% = 100 basis points).
     */
    function setIncreasePercentage(
        uint256 tokenId,
        uint256 increasePercentage
    ) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender);
        require(increasePercentage <= 10000);
        loan.increasePercentage = increasePercentage;
    }

    /**
     * @notice Sets the preferred payoff token for a specific loan.
     * @dev This function allows the borrower to set the preferred payoff token for their loan.
     *      The borrower must be the owner of the loan token.
     * @param tokenId The unique identifier of the loan.
     */
    function setPayoffToken(uint256 tokenId, bool enable) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender);
        require(loan.balance > 0);
        _setUserPayoffTokenOption(loan.borrower, enable);
        if(enable) {
           _setUserPayoffToken(loan.borrower, tokenId);
        }
    }

    /** ORACLE */
    
    /**
     * @notice Confirms the price of USDC is $1.
     * @dev This function checks the latest round data from the Chainlink price feed for USDC.
     * @return bool indicating whether the price of USDC is greater than or equal to $0.999.
     */
    function confirmUsdcPrice() virtual internal view returns (bool) {
        (
            ,
            /* uint80 roundID */ int answer /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/,
            ,
            ,

        ) = AggregatorV3Interface(address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B)).latestRoundData();

        // confirm price of usdc is $1
        return answer >= 99900000;
    }

    

    /**
     * @dev 40 Acres voting window is two hours prior to voting end
     */
    function _withinVotingWindow() internal view returns (bool) {
        return block.timestamp >= ProtocolTimeLibrary.epochVoteEnd(block.timestamp) - 2 hours;
    }

    function currentEpochStart() internal view returns (uint256) {
        return ProtocolTimeLibrary.epochStart(block.timestamp);
    }
}
