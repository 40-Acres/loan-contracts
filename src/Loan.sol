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
    address public _pool; // pool to vote on to receive fees
    IERC20 internal _asset;
    IERC20 internal _aero;
    IVotingEscrow internal _ve;
    IAerodromeRouter internal _aeroRouter;
    address internal _aeroFactory;
    address internal _rateCalculator; // deprecated
    address public _vault;

    bool public _paused;
    uint256 public _outstandingCapital;
    uint256 public  _multiplier; // rewards rate multiplier

    mapping(uint256 => LoanInfo) public _loanDetails;
    mapping(address => bool) public _approvedTokens; // deprecated

    mapping(uint256 => uint256) public _rewardsPerEpoch;
    uint256 public _lastEpochPaid; // deprecated

    
    // ZeroBalanceOption enum to handle different scenarios when the loan balance is zero
    enum ZeroBalanceOption {
        DoNothing, // do nothing when the balance is zero
        InvestToVault, // invest the balance to the vault
        PayToOwner, // pay the balance to the owner
        ReinvestVeNft // reinvest the balance to the veNFT
    }

    // LoanInfo struct to store details about each loan
    struct LoanInfo {
        uint256 tokenId;
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
        ZeroBalanceOption zeroBalanceOption;
        address[] pools;
        uint256 voteTimestamp;
        uint256 claimTimestamp;
        uint256 weight;
        uint256 unpaidFees;
        address preferredToken; 
        uint256 increasePercentage; // Percentage of the rewards to increase each lock
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
     * @dev Emitted when the zero balance option is set for a loan.
     * @param tokenId The ID of the token representing the loan.
     * @param option The zero balance option set for the loan.
     */
    event ZeroBalanceOptionSet(uint256 tokenId, ZeroBalanceOption option);
    
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
    
    event ProtocolFeePaid(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    /**
     * @dev Emitted when a user's veNFT balance is increased.
     * @param user The address of the user whose veNFT balance is increased.
     * @param tokenId The ID of the veNFT token.
     * @param amount The amount by which the veNFT balance is increased.
     */
    event VeNftIncreased(address indexed user, uint256 indexed tokenId, uint256 amount);


    /** ERROR CODES */
    error TokenNotLocked();
    error TokenLockExpired(uint256 tokenId);
    error InvalidLoanAmount();
    error PriceNotConfirmed();
    error LoanNotFound(uint256 tokenId);
    error NotOwnerOfToken(uint256 tokenId, address owner);
    error LoanActive(uint256 tokenId);

    constructor() {
        _disableInitializers();
    }

    function initialize(address vault, address asset) initializer virtual public {
        __Ownable_init(msg.sender); //set owner to msg.sender
        __UUPSUpgradeable_init();
        address[] memory pools = new address[](1);
        pools[0] = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;

        _defaultPoolChangeTime = block.timestamp;
        _vault = vault;
        _voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
        _rewardsDistributor = IRewardsDistributor(0x227f65131A261548b057215bB1D5Ab2997964C7d);
        _asset = IERC20(asset);
        _aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
        _ve = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
        _aeroRouter = IAerodromeRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
        _aeroFactory = address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}



}