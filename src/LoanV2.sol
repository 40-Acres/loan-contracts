// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "./interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
import {ISwapper} from "./interfaces/ISwapper.sol";
import {LoanUtils} from "./LoanUtils.sol";
import { IMarketViewFacet } from "./interfaces/IMarketViewFacet.sol";
import {IFlashLoanProvider} from "./interfaces/IFlashLoanProvider.sol";
import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";
import { PortfolioFactory } from "./accounts/PortfolioFactory.sol";

contract Loan is ReentrancyGuard, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, RateStorage, LoanStorage {
    // initial contract parameters are listed here
    // parameters introduced after initial deployment are in NamedStorage contracts
    IVoter internal _voter;
    IRewardsDistributor internal _rewardsDistributor;
    address private _pool; // deprecated
    IERC20 public _asset;
    IERC20 internal _aero;
    IVotingEscrow public _ve;
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
    //// end of deprecated storage variables

    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
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
        bool    optInCommunityRewards; // opt in to community rewards
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
     * @dev Emitted when rewards are sent to the vault to lenders as a premium.
     * @param tokenId The ID of the token representing the loan.
     * @param borrower The address of the borrower repaying the loan.
     * @param amount The amount repaid.
     * @param epoch The epoch during which the repayment occurred.
     * @param isManual Indicates whether the repayment was manual.
     */
    
    event LoanPaid(uint256 tokenId, address borrower, uint256 amount, uint256 epoch, bool isManual);
    /**
     * @dev Emitted when rewards are used to repay a loan balance.
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
     * @param token The address of the token in which the rewards are claimed.
     */
    
    event RewardsClaimed(uint256 epoch, uint256 amount, address borrower, uint256 tokenId, address token);
    /**
     * @dev Emitted when rewards are paid to the owner of the loan.
     * @param epoch The epoch during which the rewards were paid.
     * @param amount The amount of rewards paid.
     * @param borrower The address of the borrower associated with the loan.
     * @param tokenId The ID of the token representing the loan.
     * @param token The address of the token in which the rewards are paid.
     */
    event RewardsPaidtoOwner(uint256 epoch, uint256 amount, address borrower, uint256 tokenId, address token);    
    
    /**
     * @dev Emitted when a loan's borrower is updated by an authorized caller.
     */
    event BorrowerChanged(uint256 indexed tokenId, address indexed previousBorrower, address indexed newBorrower, address caller);
    
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
     * @param epoch The epoch during which the veNFT balance was increased
     * @param user The address of the user whose veNFT balance is increased.
     * @param tokenId The ID of the veNFT token being increased.
     * @param amount The amount by which the veNFT balance is increased.
     * @param fromToken The token from which the amount is derived.
     */
    event VeNftIncreased(uint256 epoch, address indexed user, uint256 indexed tokenId, uint256 amount, uint256 indexed fromToken);
    
    /**
     * @dev Emitted when a flash loan is executed.
     * @param receiver The address of the contract receiving the funds.
     * @param initiator The address initiating the flash loan.
     * @param token The address of the token being borrowed.
     * @param amount The amount of tokens being borrowed.
     * @param fee The fee charged for the flash loan.
     */
    event FlashLoan(address indexed receiver, address indexed initiator, address indexed token, uint256 amount, uint256 fee);
    
    /** ERROR CODES */
    // error TokenNotLocked();
    // error TokenLockExpired(uint256 tokenId);
    // error InvalidLoanAmount();
    // error PriceNotConfirmed();
    // error LoanNotFound(uint256 tokenId);
    // error NotOwnerOfToken(uint256 tokenId, address owner);
    // error LoanActive(uint256 tokenId);
    
    // Flash loan error codes
    error UnsupportedToken(address token);
    error ExceededMaxLoan(uint256 maxLoan);
    error InvalidFlashLoanReceiver(address receiver);
    
    // General validation errors (reusable)
    error InvalidOffer();
    error InvalidListing();
    error Unauthorized();
    error LoanNotPaidOff();
    error SellerMismatch();
    error CreatorMismatch();
    error FlashLoansPaused();
    error InsufficientAllowance(uint256 required, uint256 available);
    error MarketNotConfigured();
    error ZeroAddress();

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
     * @dev Modifier to ensure the caller is the market diamond.
     * @notice market diamond must be configured for loan listings and LBO to work properly
     */
    modifier onlyMarketDiamond() {
        address marketDiamond = getMarketDiamond();
        if (marketDiamond == address(0)) revert MarketNotConfigured();
        if (msg.sender != marketDiamond) revert Unauthorized();
        _;
    }

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
    ) public virtual {
        // require the msg.sender to be the owner of the token
        address owner = _ve.ownerOf(tokenId);
        require(owner == msg.sender);

        _lock(tokenId);

        _loanDetails[tokenId] = LoanInfo({
            tokenId: tokenId,
            balance: 0,
            borrower: msg.sender,
            timestamp: block.timestamp,
            outstandingCapital: 0,
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


        // transfer the token to the contract if not a user account
        bool isAccount = isUserAccount(msg.sender);
        if(!isAccount) {
            _ve.transferFrom(msg.sender, address(this), tokenId);
        }
        emit CollateralAdded(tokenId, msg.sender, zeroBalanceOption);


        require(increasePercentage <= 10000);
        if(preferredToken != address(0)) {
            require(isApprovedToken(preferredToken));
        }
        
        _loanDetails[tokenId].weight = _getLockedAmount(tokenId);
        require(_loanDetails[tokenId].weight >= getMinimumLocked());
        addTotalWeight(_loanDetails[tokenId].weight);

        // if user selects topup option, increase to the max loan amount
        if(topUp) {
            (amount,) = getMaxLoan(tokenId);
        }

        if (amount > 0) {
            increaseLoan(tokenId, amount);
        }

        vote(tokenId);
        require(_ve.ownerOf(tokenId) == address(this) || isAccount);
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
        // Check if caller is a user account - if so, don't require NFT to be locked in loan contract
        bool isAccount = false;
        PortfolioFactory portfolioFactory = PortfolioFactory(getPortfolioFactory());
        if (address(portfolioFactory) != address(0)) {
            try portfolioFactory.isUserAccount(msg.sender) returns (bool exists) {
                isAccount = exists;
            } catch {
                // If the call fails, assume it's not a user account
                isAccount = false;
            }
        }
            
        require(_ve.ownerOf(tokenId) == address(this) || isAccount);
        
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
        _asset.transferFrom(_vault, loan.borrower, amount);
        emit FundsBorrowed(tokenId, loan.borrower, amount);
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

        _asset.transferFrom(msg.sender, address(this), amount);
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
     * @param isManual Indicates whether the payment is made manually via pay function or automatically via claim flow.
     */
    function _pay(uint256 tokenId, uint256 amount, bool isManual) internal {
        if (amount == 0) {
            return;
        }
        LoanInfo storage loan = _loanDetails[tokenId];

        // take out unpaid fees first
        if(loan.unpaidFees > 0) {
            uint256 feesPaid = loan.unpaidFees;
            // set maxFees to 25% of the amount being paid
            uint256 maxFees = (amount * 25) / 100; // 25% of the amount being paid
            if(feesPaid > maxFees) {
                feesPaid = maxFees; // cap the fees paid to 25% of the amount being paid
            }
            amount -= feesPaid;
            loan.unpaidFees -= feesPaid;
            loan.balance -= feesPaid;
            _asset.transfer(owner(), feesPaid);
            emit LoanPaid(tokenId, loan.borrower, feesPaid, currentEpochStart(), isManual);
            emit ProtocolFeePaid(currentEpochStart(), feesPaid, loan.borrower, tokenId, address(_asset));
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

        _asset.transfer(_vault, amount);
        emit LoanPaid(tokenId, loan.borrower, amount, currentEpochStart(), isManual);
        // if there is an excess payment, handle it according to the zero balance option
        if (excess > 0) {
            _handleZeroBalance(tokenId, excess, excess, true);
        }

        if(!isManual && loan.topUp && confirmUsdcPrice()) {
            (uint256 maxLoan, ) = getMaxLoan(tokenId);
            if(maxLoan > .01e6) {
                _increaseLoan(loan, tokenId, maxLoan);
            }
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

        LoanInfo storage payoffLoan = _loanDetails[payoffToken];
        if(payoffLoan.borrower != borrower) {
            return 0; // not the borrower of the payoff loan
        }
        uint256 payoffAmount = amount;
        if(payoffAmount > payoffLoan.balance) {
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
    function incentivizeVault(uint256 amount) virtual public {
        _asset.transferFrom(msg.sender, _vault, amount);
        recordRewards(amount, msg.sender, type(uint256).max);
    }
    
    /**
     * @dev Handles the distribution of rewards or balances based on the zero balance option set for a loan.
     *      This function is internal and is used to process rewards or balances when a loan reaches a zero balance.
     * @param tokenId The ID of the loan token.
     * @param remaining The amount able to paid in fees.
     * @param totalRewards The total amount of rewards claimed for the loan.
     * @param wasActiveLoan A boolean indicating whether the loan had a balance when rewards were claimed originally.
     *
     * The function supports the following zero balance options:
     * - `InvestToVault`: Invests the amount into a vault on behalf of the borrower.
     * - `PayToOwner`: Pays the amount to the borrower.
     * - `DoNothing`: Transfers the amount to the borrower without any additional processing.
     */
    function _handleZeroBalance(uint256 tokenId, uint256 remaining, uint256 totalRewards, bool wasActiveLoan) internal {
        LoanInfo storage loan = _loanDetails[tokenId];
        // InvestToVault: invest the amount to the vault on behalf of the borrower
        // In the rare event a user may be blacklisted from  USDC, we invest to vault directly for the borrower to avoid any issues.
        // The user may withdraw their investment later if they are unblacklisted.
        if (loan.zeroBalanceOption == ZeroBalanceOption.InvestToVault || wasActiveLoan) {
            remaining -= _payZeroBalanceFee(loan.borrower, tokenId, remaining, totalRewards, address(_asset));
            _asset.approve(_vault, remaining);
            IERC4626(_vault).deposit(remaining, loan.borrower);
            emit RewardsInvested(currentEpochStart(), remaining, loan.borrower, tokenId);
            return;
        }
        // If PayToOwner or DoNothing, send tokens to the borrower and pay applicable fees
        IERC20 asset = loan.preferredToken == address(0) ? _asset : IERC20(loan.preferredToken);
        remaining -= _payZeroBalanceFee(loan.borrower, tokenId, remaining, totalRewards, address(asset));
        emit RewardsPaidtoOwner(currentEpochStart(), remaining, loan.borrower, tokenId, address(asset));
        require(asset.transfer(loan.borrower, remaining));
    }


    /**
     * @dev Handles the payment of zero balance fees for a given loan.
     * @param borrower The address of the borrower.
     * @param tokenId The ID of the loan token.
     * @param remaining The token balance available for payment.
     * @param totalRewards The total amount of rewards claimed for the loan.
     * @param token The address of the token being used for payment.
     * @return fee The amount of the zero balance fee paid.
     */
    function _payZeroBalanceFee(address borrower, uint256 tokenId, uint256 remaining, uint256 totalRewards, address token) internal returns (uint256) {
        uint256 zeroBalanceFee = (totalRewards * getZeroBalanceFee()) / 10000;
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
    function claim(uint256 tokenId, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) public virtual returns (uint256) {
        // require(msg.sender == _entryPoint());
        LoanInfo storage loan = _loanDetails[tokenId];

        // If the loan has no borrower or the token is not locked in the contract, exit early.
        if (loan.borrower == address(0)) {
            return 0;
        }

        // If the loan balance is zero and the zero balance option is set to DoNothing, exit early.
        if (loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.DoNothing) {
            return 0;
        }

        // if any of tokens or loan.preferres token has a balance, return to owner
        _rescueTokens(tokens, loan.preferredToken == address(0) ? address(_asset) : loan.preferredToken);

        _processRewards(fees, tokens, tokenId, tradeData);
        uint256 rewardsAmount = _asset.balanceOf(address(this));
        address rewardToken = address(_asset);
        // If the loan balance is zero and the user does not use a payoff token or the payoff token is zero, 
        // then it means the loan is fully paid off.
        // If the zero balance option is set to PayToOwner, we will pay the rewards to the owner in the desired token.
        if (loan.balance == 0 && 
            (!userUsesPayoffToken(loan.borrower) || getUserPayoffToken(loan.borrower) == 0) && 
            loan.zeroBalanceOption == ZeroBalanceOption.PayToOwner) {
            rewardToken = loan.preferredToken == address(0) ? address(_asset) : loan.preferredToken;
            rewardsAmount = IERC20(rewardToken).balanceOf(address(this));
        }

       // if allocations[1] is lower than aero amount, set aero amount to allocations[1]
        uint256 aeroAmount = _aero.balanceOf(address(this));
        if (allocations[1] < aeroAmount) {
            aeroAmount = allocations[1];
        }

        // if rewards token is the same as aero, subtract aero amount from rewards amount
        if(rewardToken == address(_aero)) {
            rewardsAmount -= aeroAmount; 
        }

        require(rewardsAmount > 0 || aeroAmount > 0);
        // Emit an event indicating that rewards have been claimed.
        emit RewardsClaimed(currentEpochStart(), allocations[0], loan.borrower, tokenId, address(rewardToken));


        // Handle zero balance case
        if (loan.balance == 0 && (!userUsesPayoffToken(loan.borrower) || getUserPayoffToken(loan.borrower) == 0)) {
            _handleZeroBalanceClaim(loan, rewardsAmount, allocations[0], aeroAmount);
        } else {
            // Handle active loan case
            _handleActiveLoanClaim(loan, tokenId, allocations[0], aeroAmount, rewardsAmount);
        }

        _claimRebase(loan);
        require(_ve.ownerOf(tokenId) == address(this));
        
        return allocations[0];
    }

    function _processRewards(
        address[] calldata fees,
        address[][] calldata tokens,
        uint256 tokenId,
        bytes calldata tradeData
    ) virtual internal {
        _voter.claimFees(fees, tokens, tokenId);
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

    /**
     * @notice Returns the address of the ODOS Router contract.
     * @dev This function is used to interact with the ODOS Router for trading and swapping tokens.
     * @return The address of the ODOS Router contract.
     */
    function odosRouter() public virtual pure returns (address) {
        return 0x19cEeAd7105607Cd444F5ad10dd51356436095a1; // ODOS Router address
    }

    /**
     * @notice Handles claim process when loan balance becomes zero.
     * @dev Increases NFT balance and processes zero balance state.
     * @param loan The loan information storage struct
     * @param remaining The remaining token amount after processing
     * @param totalRewards The total rewards accumulated
     * @param amountToIncrease The amount to increase the NFT by
     */
    function _handleZeroBalanceClaim(
        LoanInfo storage loan, 
        uint256 remaining,
        uint256 totalRewards,
        uint256 amountToIncrease
    ) internal {
        _increaseNft(loan, amountToIncrease, true);
        _handleZeroBalance(loan.tokenId, remaining, totalRewards, false);
    }

    /**
     * @notice Handles claiming rewards for an active loan
     * @dev Processes fee deductions, increases NFT value, and handles payoff tokens
     * @param loan The storage reference to the loan information
     * @param tokenId The ID of the token associated with the loan
     * @param totalRewards The total rewards being claimed
     * @param amountToIncrease The amount by which to increase the NFT value
     * @param remaining The remaining amount after initial calculations, which gets updated throughout the function
     */
    function _handleActiveLoanClaim(
        LoanInfo storage loan,
        uint256 tokenId, 
        uint256 totalRewards,
        uint256 amountToIncrease,
        uint256 remaining
    ) internal {
        // Calculate fee eligible amount
        uint256 feeEligibleAmount = _calculateFeeEligibleAmount(loan, totalRewards);
        
        // Process fees
        remaining -= _processFees(loan, tokenId, feeEligibleAmount, remaining);
        
        // Handle NFT increase
        _increaseNft(loan, amountToIncrease, false);
        // Handle payoff token and payment
        remaining -= _handlePayoffToken(loan.borrower, tokenId, remaining);
        _pay(tokenId, remaining, false);
    }

    /**
     * @notice Process and distribute fees from loan rewards
     * @dev Calculates protocol fee and lender premium based on total rewards, transfers them accordingly,
     *      and records the lender premium rewards
     * @param loan The loan information storage struct
     * @param tokenId The NFT token ID associated with the loan
     * @param totalRewards The total rewards amount to process fees from
     * @param remaining The remaining amount after previous deductions (unused in current implementation)
     * @return The sum of the protocol fee and lender premium
     */
    function _processFees(
        LoanInfo storage loan,
        uint256 tokenId,
        uint256 totalRewards,
        uint256 remaining
    ) internal returns (uint256) {
        // Calculate and transfer protocol fee
        uint256 protocolFee = (totalRewards * getProtocolFee()) / 10000;
        _asset.transfer(owner(), protocolFee);
        emit ProtocolFeePaid(currentEpochStart(), protocolFee, loan.borrower, tokenId, address(_asset));

        // Calculate and transfer lender premium
        uint256 lenderPremium = (totalRewards * getLenderPremium()) / 10000;
        _asset.transfer(_vault, lenderPremium);
        recordRewards(lenderPremium, loan.borrower, tokenId);
        return protocolFee + lenderPremium;
    }

    /**
     * @notice Calculates the portion of an amount that is eligible for fees
     * @dev If the borrower is using a payoff token different from the current loan's token,
     *      the fee eligible amount is capped at the sum of the current loan balance and the payoff token loan balance.
     *      Otherwise, the entire amount is eligible for fees.
     * @param loan The loan information stored in the contract
     * @param amount The total amount being processed
     * @return feeEligibleAmount The portion of the amount that is eligible for fees
     */
    function _calculateFeeEligibleAmount(LoanInfo storage loan, uint256 amount) internal view returns (uint256) {
        uint256 feeEligibleAmount = amount;
        uint256 payoffTokenLoanBalance = 0;
        
        if (userUsesPayoffToken(loan.borrower) && getUserPayoffToken(loan.borrower) != 0 && getUserPayoffToken(loan.borrower) != loan.tokenId) {
            payoffTokenLoanBalance = _loanDetails[getUserPayoffToken(loan.borrower)].balance;
        }
        
        if (amount > loan.balance + payoffTokenLoanBalance) {
            feeEligibleAmount = loan.balance + payoffTokenLoanBalance;
        }
        
        return feeEligibleAmount;
    }

    /**
     * @dev Internal function to increase the
      NFT-related value for a loan.
     * @param loan The LoanInfo struct containing details of the loan.
     * @param allocation The amount  to be allocated for increasing the veNFT balance.
     * @return spent The amount spent to increase the veNFT balance, or 0 if no increase is made.
     */
    function _increaseNft(LoanInfo storage loan, uint256 allocation, bool takeFees) internal  returns (uint256 spent) {
        if(loan.increasePercentage > 0 && allocation == 0) {
            revert(); // Should be an allocation if increasePercentage is set
        }
        if(allocation == 0) {
            return 0;
        }
        _aero.approve(address(_ve), allocation);
        _ve.increaseAmount(loan.tokenId, allocation);
        emit VeNftIncreased(currentEpochStart(), loan.borrower, loan.tokenId, allocation, loan.tokenId);
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

    function increaseAmount(uint256 tokenId, uint256 amount) public {
        require(_ve.ownerOf(tokenId) == address(this));
        require(amount > 0);
        require(_aero.transferFrom(msg.sender, address(this), amount));
        _aero.approve(address(_ve), amount);
        _ve.increaseAmount(tokenId, amount);
        emit VeNftIncreased(currentEpochStart(), msg.sender, tokenId, amount, tokenId);
        addTotalWeight(amount);
        LoanInfo storage loan = _loanDetails[tokenId];
        loan.weight += amount;
    }

    /**
     * @notice Allows the borrower to claim their collateral (veNFT) after the loan is fully repaid.
     * @dev This function ensures that only the borrower can claim the collateral and that the loan is fully repaid.
     *      If the loan balance is greater than zero, the collateral cannot be claimed.
     * @param tokenId The ID of the loan (NFT) whose collateral is being claimed.
     */
    function claimCollateral(uint256 tokenId) public virtual {
        LoanInfo storage loan = _loanDetails[tokenId];

        // Ensure that the caller is the borrower of the loan
        require(loan.borrower == msg.sender);

        // Ensure that the loan is fully repaid before allowing collateral to be claimed
        require(loan.balance == 0);

        // transfer the token to the contract if not a user account
        bool isAccount = isUserAccount(msg.sender);
        if(!isAccount) {
            _ve.transferFrom(address(this), loan.borrower, tokenId);
        }
        emit CollateralWithdrawn(tokenId, msg.sender);
        subTotalWeight(loan.weight);
        delete _loanDetails[tokenId];
    }

    /**
     * @notice Calculates the maximum loan amount that can be borrowed for a given token ID.
     * @dev This function forwards the call to the LoanCalculator contract.
     * @param tokenId The ID of the loan (NFT).
     * @return maxLoan The maximum loan amount that can be borrowed.
     * @return maxLoanIgnoreSupply The maximum loan amount ignoring vault supply constraints.
     */
    function getMaxLoan(
        uint256 tokenId
    ) public virtual view returns (uint256, uint256) {
        return LoanUtils.getMaxLoanByRewardsRate(
            _getLockedAmount(tokenId),
            getRewardsRate(),
            _multiplier,
            _asset.balanceOf(_vault),
            _outstandingCapital,
            _loanDetails[tokenId].balance
        );
    }

    /**
     * @notice Records the rewards for the current epoch.
     * @dev This function adds the specified rewards to the total rewards for the current epoch.
     * @param rewards The amount of rewards to record.
     */
    function recordRewards(uint256 rewards, address borrower, uint256 tokenId) internal virtual {
        if (rewards > 0) {
            _rewardsPerEpoch[currentEpochStart()] += rewards;
            emit RewardsReceived(currentEpochStart(), rewards, borrower, tokenId);
        }
    }

    /* Rate Methods */

    /**
     * @notice Retrieves the zero balance fee percentage.
     * @dev This function checks the zero balance fee stored in the RateStorage contract.
     * @return The zero balance fee with 6 decimal precision.
     */
    function getZeroBalanceFee() public view override returns (uint256) {
        uint256 zeroBalanceFee = RateStorage.getZeroBalanceFee();
        return zeroBalanceFee;
    }


    /**
     * @notice Retrieves the rewards rate for the current epoch .
     * @dev This function checks the rewards rate stored in the RateStorage contract.
    * @return The rewards rate with 6 decimal precision.
     */
    function getRewardsRate() public view override returns (uint256) {
        uint256 rewardsRate = RateStorage.getRewardsRate();
        return rewardsRate;
    }

    /**
     * @notice Retrieves the lender premium percentage.
     * @dev This function checks the lender premium stored in the RateStorage contract.
     * @return The lender premium with 6 decimal precision.
     */
    function getLenderPremium() public view override returns (uint256) {
        uint256 lenderPremium = RateStorage.getLenderPremium();
        return lenderPremium;
    }

    /**
     * @notice Retrieves the protocol fee percentage.
     * @dev This function checks the protocol fee stored in the RateStorage contract.
     * @return The protocol fee with 6 decimal precision.
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
     * @notice Gets the loan weight for a specific token ID.
     * @param tokenId The ID of the loan (NFT).
     * @return weight The weight of the loan.
     */
    function getLoanWeight(
        uint256 tokenId
    ) public view returns (uint256 weight) {
        LoanInfo storage loan = _loanDetails[tokenId];
        return loan.weight;
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
     * @notice Allows user to merge their veNFT into another veNFT.
     * @dev This function can only be called by the owner of the veNFT being merged.
     * @param from The ID of the token to merge from.
     * @param to The ID of the token to merge to.
     */
    function merge(uint256 from, uint256 to) virtual public {
        require(_ve.ownerOf(to) == address(this));
        require(_ve.ownerOf(from) == msg.sender);
        LoanInfo storage loan = _loanDetails[to];
        require(loan.borrower == msg.sender);
        uint256 beginningBalance = _getLockedAmount(to);
        _ve.merge(from, to);
        uint256 weightIncrease = _getLockedAmount(to) - beginningBalance;
        addTotalWeight(weightIncrease);
        loan.weight += weightIncrease;
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
    function setApprovedPools(address[] calldata pools, bool enable) public virtual onlyOwner {
        for (uint256 i = 0; i < pools.length; i++) {
            // confirm pool is a valid gauge
            address gauge = _voter.gauges(pools[i]);
            if (enable) require(_voter.isAlive(gauge));
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


    /**
     * @notice Rescue any ERC20 tokens that are stuck in the contract.
     * @dev This function can only be called by the owner of the contract.
     * @param tokens An array of addresses of the ERC20 tokens to rescue.
     * @param additionalToken The address of the asset to rescue.
     */
    function _rescueTokens(address[][] calldata tokens, address additionalToken) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            for(uint256 j = 0; j < tokens[i].length; j++) {
            IERC20 token = IERC20(tokens[i][j]);
                uint256 balance = token.balanceOf(address(this));
                if (balance > 0) {
                    token.transfer(owner(), balance);
                }
            }
        }
        // check additional token
        if (additionalToken != address(0)) {
            IERC20 additional = IERC20(additionalToken);
            uint256 additionalBalance = additional.balanceOf(address(this));
            if (additionalBalance > 0) {
                additional.transfer(owner(), additionalBalance);
            }
        }

        // check aero balance
        uint256 aeroBalance = _aero.balanceOf(address(this));
        if (aeroBalance > 0) {
            _aero.transfer(owner(), aeroBalance);
        }
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
    
    function setOptInCommunityRewards(
        uint256[] calldata tokenIds,
        bool optIn
    ) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            LoanInfo storage loan = _loanDetails[tokenIds[i]];
            require(loan.borrower == msg.sender);
            loan.optInCommunityRewards = optIn;
        }
    }


    /**
     * @notice Allows the borrower to vote on pools for their loan.
     * @dev This function can only be called by the borrower of the loan.
     *      The pools must have valid gauges, and the weights must sum up to 100e18 (100%).
     * @notice The tokens must be votes on at least every 14 days or the token will vote for the default pools.
     * @param tokenIds An array of token IDs representing the loans for which the vote is being cast.
     * @param pools An array of addresses representing the pools to vote on.
     * @param weights An array of uint256 values representing the weights of the pools.
     */
    function userVote(
        uint256[] calldata tokenIds,
        address[] calldata pools,
        uint256[] calldata weights
    ) public {
        // if pools/weights are empty, reset timestamp so user will be in automatic voting mode
        if(pools.length == 0 && weights.length == 0) {
            for (uint256 i = 0; i < tokenIds.length; i++) {
            LoanInfo storage loan = _loanDetails[tokenIds[i]];
                require(loan.borrower == msg.sender);
                loan.voteTimestamp = 0;
            }
            return;
        }
        _validatePoolChoices(pools, weights);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _vote(tokenIds[i], pools, weights);
        }
    }

    /**
     * @notice Allows anyone to vote on the default pools for the nft.
     * @dev This function can only be called on the last day of the epoch during the voting window.
     * @param tokenId The ID of the loan (NFT) for which the vote is being cast.
     * @return bool indicating whether the vote was successfully cast.
     */
    function vote(uint256 tokenId) public returns (bool) {
        address[] memory pools = new address[](0);
        uint256[] memory weights = new uint256[](0);
        return _vote(tokenId, pools, weights);
    }

    /**
     * @dev Internal function to handle voting for a specific loan.
    * @param tokenId The ID of the loan (NFT) for which the vote is being cast.
     * @param pools An array of addresses representing the pools to vote on.
     * @param weights An array of uint256 values representing the weights of the pools.
     * @return bool indicating whether the vote was successfully cast.
     */
    function _vote(uint256 tokenId, address[] memory pools, uint256[] memory weights) internal virtual returns (bool) {
        LoanInfo storage loan = _loanDetails[tokenId];
        bool isAccount = isUserAccount(msg.sender);
        IVoter voter = _voter;
        // Always use the actual voter contract, not the FortyAcresPortfolioAccount
        if(loan.borrower == msg.sender && pools.length > 0) {
            // not within try catch because we want to revert if the transaction fails so the user can try again
            voter.vote(tokenId, pools, weights); 
            loan.voteTimestamp = block.timestamp;
            return true; // if the user has manually voted, we don't want to override their vote
        }
        
        bool isActive = ProtocolTimeLibrary.epochStart(loan.voteTimestamp) > ProtocolTimeLibrary.epochStart(block.timestamp) - 14 days;
        if(!isActive && _withinVotingWindow()) {
            try voter.vote(tokenId, _defaultPools, _defaultWeights) {
                return true;
            } catch { }
        } 
        return false;
    }
    


    function _lock(uint256 tokenId) internal virtual {
        // ensure the token is locked permanently
        IVotingEscrow.LockedBalance memory lockedBalance = _ve.locked(tokenId);
        if (!lockedBalance.isPermanent) {
            require(lockedBalance.end > block.timestamp);
            _ve.lockPermanent(tokenId); 
        }
    }
    

    function _getLockedAmount(
        uint256 tokenId
    ) internal view virtual returns (uint256) {
        IVotingEscrow.LockedBalance memory lockedBalance = _ve.locked(tokenId);
        if (
            !lockedBalance.isPermanent && lockedBalance.end < ProtocolTimeLibrary.epochStart(block.timestamp)
        ) {
            return 0;
        }
        require(lockedBalance.amount >= 0);
        return uint256(uint128(lockedBalance.amount));
    }
    /**
     * @notice Sets the increase percentage for a specific loan.
     * @dev This function allows the borrower to set the increase percentage for their loan.
     *      The increase percentage must not exceed 100% (represented as 10000).
     * @param tokenId The unique identifier of the loan.
     * @param increasePercentage The new increase percentage to be set, in basis points (1% = 100).
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
     * @param enable A boolean indicating whether to enable or disable the preferred payoff token option.
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
            /* uint80 roundID */,
            int answer ,
            /*uint startedAt*/,
            uint256 timestamp,
            /*uint80 answeredInRound*/

        ) = AggregatorV3Interface(address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B)).latestRoundData();

        // add staleness check, data updates every 24 hours
        require(timestamp > block.timestamp - 25 hours);
        // confirm price of usdc is $1
        return answer >= 99900000;
    }

    /**
     * @dev 40 Acres voting window is two hours prior to voting end
     */
    function _withinVotingWindow() internal view returns (bool) {
        return block.timestamp >= ProtocolTimeLibrary.epochVoteEnd(block.timestamp) - 1 hours;
    }

    function currentEpochStart() internal view returns (uint256) {
        return ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    function _entryPoint() internal view virtual returns (address) {
        return 0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA;
    }


    // /**
    //  * @notice Sets the borrower for a specific loan.
    //  * @dev This function can only be called by an approved contract.
    //  * @param tokenId The ID of the loan (NFT).
    //  * @param newBorrower The address of the new borrower.
    //  */
    // function _setBorrower(uint256 tokenId, address newBorrower) internal {
    //     if (newBorrower == address(0)) revert ZeroAddress();
    //     LoanInfo storage loan = _loanDetails[tokenId];
    //     if (loan.borrower != msg.sender && msg.sender != getMarketDiamond()) revert Unauthorized();
    //     address previousBorrower = loan.borrower;
    //     loan.borrower = newBorrower;
    //     emit BorrowerChanged(tokenId, previousBorrower, newBorrower, msg.sender);
    // }

    // function finalizeMarketPurchase(uint256 tokenId, address buyer, address expectedSeller) external onlyMarketDiamond {
    //     if (buyer == address(0)) revert ZeroAddress();

    //     // Verify listing presence and consistency via MarketView facet on the diamond caller
    //     (address listingOwner, , , , uint256 expiresAt) = IMarketViewFacet(msg.sender).getListing(tokenId);
    //     if (listingOwner == address(0)) revert InvalidListing();
    //     if (expiresAt != 0 && block.timestamp >= expiresAt) revert InvalidListing();

    //     LoanInfo storage loan = _loanDetails[tokenId];
    //     if (loan.borrower != expectedSeller || listingOwner != expectedSeller) revert SellerMismatch();
    //     if (loan.balance != 0) revert LoanNotPaidOff();

    //     _setBorrower(tokenId, buyer);
    // }

    // /**
    //  * @notice Finalize offer acceptance by setting borrower post-payoff in the same tx
    //  * @dev Callable ONLY by market diamond; requires loan payoff is complete and seller identity matches
    //  */
    // function finalizeOfferPurchase(uint256 tokenId, address buyer, address expectedSeller, uint256 offerId) external onlyMarketDiamond {
    //     if (buyer == address(0)) revert ZeroAddress();

    //     // Validate the offer is present and active, and belongs to the buyer
    //     (
    //         address creator,
    //         ,
    //         ,
    //         ,
    //         ,
    //         uint256 expiresAt
    //     ) = IMarketViewFacet(msg.sender).getOffer(offerId);
    //     if (creator == address(0)) revert InvalidOffer();
    //     if (creator != buyer) revert CreatorMismatch();
    //     if (expiresAt != 0 && block.timestamp >= expiresAt) revert InvalidOffer();

    //     LoanInfo storage loan = _loanDetails[tokenId];
    //     if (loan.borrower != expectedSeller) revert SellerMismatch();
    //     // debts should be paid off already
    //     if (loan.balance != 0) revert LoanNotPaidOff();

    //     _setBorrower(tokenId, buyer);
    // }

    // function finalizeLBOPurchase(uint256 tokenId, address buyer) external onlyMarketDiamond {
    //     if (buyer == address(0)) revert ZeroAddress();
        
    //     LoanInfo storage loan = _loanDetails[tokenId];
    //     if (loan.borrower != msg.sender) revert Unauthorized(); // Market diamond should be current borrower

    //     loan.balance -= loan.unpaidFees;
    //     loan.unpaidFees = 0;
        
    //     require(loan.balance == loan.outstandingCapital + loan.unpaidFees);

    //     // Transfer veNFT ownership to buyer
    //     _setBorrower(tokenId, buyer);
    // }

    // /* FLASH LOAN FUNCTIONS */

    // /**
    //  * @notice Returns the maximum amount of tokens available for a flash loan
    //  * @dev Implements the IFlashLoanProvider interface
    //  * @param token The address of the token to be flash loaned
    //  * @return The maximum amount of tokens available for flash loan
    //  */
    // function maxFlashLoan(address token) public view override returns (uint256) {
    //     if (token != address(_asset)) {
    //         return 0;
    //     }
        
    //     // The maximum flash loan amount is the total balance in the vault
    //     return _asset.balanceOf(_vault);
    // }

    // /**
    //  * @notice Calculates the fee for a flash loan
    //  * @dev Implements the IFlashLoanProvider interface
    //  * @param token The address of the token to be flash loaned
    //  * @param amount The amount of tokens to be loaned
    //  * @return The flash loan fee
    //  */
    // function flashFee(address token, uint256 amount) public view override returns (uint256) {
    //     if (token != address(_asset)) {
    //         revert UnsupportedToken(token);
    //     }
        
    //     // 0% fee for market diamond, regular fee for others
    //     if (msg.sender == getMarketDiamond()) {
    //         return 0;
    //     }
        
    //     return (amount * getFlashLoanFee()) / 10000; // Fee is in basis points
    // }

    // /**
    //  * @notice Executes a flash loan
    //  * @dev Implements the IFlashLoanProvider interface
    //  * @param receiver The contract receiving the flash loan
    //  * @param token The token to be flash loaned
    //  * @param amount The amount of tokens to be loaned
    //  * @param data Additional data to be passed to the receiver. Must contain the LBO purchaseOrder struct to call buyToken on MarketRouterFacet
    //  * @return success Boolean indicating whether the flash loan was successful
    //  */
    // function flashLoan(
    //     IFlashLoanReceiver receiver,
    //     address token,
    //     uint256 amount,
    //     bytes calldata data
    // ) external override nonReentrant onlyMarketDiamond returns (bool) {
    //     // Check if flash loan is paused
    //     if (getFlashLoanPaused()) revert FlashLoansPaused();

    //     // require flash loan receiver to be market diamond
    //     if (address(receiver) != getMarketDiamond()) revert InvalidFlashLoanReceiver(address(receiver));

    //     // will revert if token is not supported
    //     if (token != address(_asset)) {
    //         revert UnsupportedToken(token);
    //     }
        
    //     // Check if the amount exceeds the maximum available
    //     uint256 maxLoan = maxFlashLoan(token);
    //     if (amount > maxLoan) {
    //         revert ExceededMaxLoan(maxLoan);
    //     }
        
    //     // Calculate the fee (0% for LBO operations from market diamond)
    //     uint256 fee = flashFee(token, amount);
        
    //     // Transfer the loan amount from the vault to the receiver
    //     // For flash loans to work, the vault needs to approve this contract to transfer funds
    //     // This is similar to how _increaseLoan function works
    //     _asset.transferFrom(_vault, address(receiver), amount);
        
    //     // Execute the callback on the receiver
    //     if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != CALLBACK_SUCCESS) {
    //         revert InvalidFlashLoanReceiver(address(receiver));
    //     }
        
    //     // Ensure the contract has enough allowance to transfer the funds back to the vault
    //     uint256 receiverAllowance = _asset.allowance(address(receiver), address(this));
    //     uint256 required = amount + fee;
    //     if (receiverAllowance < required) revert InsufficientAllowance(required, receiverAllowance);
        
    //     // Transfer the loan amount plus fee back to the vault
    //     _asset.transferFrom(address(receiver), _vault, amount + fee);
        
    //     // flash loans are restricted to market diamond which is charged 0 flash loan fee
        
    //     // Emit the flash loan event
    //     emit FlashLoan(address(receiver), msg.sender, token, amount, fee);
        
    //     return true;
    // }
    
    function isUserAccount(address owner) public view returns (bool) {
        address portfolioFactory = getPortfolioFactory();
        if(portfolioFactory != address(0)) {
            try PortfolioFactory(portfolioFactory).isUserAccount(owner) returns (bool exists) {
                return exists;
            } catch {}
        }
        return false;
    }
}
