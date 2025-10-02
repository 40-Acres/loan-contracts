// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "../interfaces/IAerodromeRouter.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";
import { IRouter } from "../interfaces/IRouter.sol";
import {Loan } from "../Loan.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IXVoter} from "../interfaces/IXVoter.sol";
import {RateStorage} from "../RateStorage.sol";
import {LoanStorage} from "../LoanStorage.sol";



contract EtherexLoan is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, RateStorage, LoanStorage {
    IXVoter internal _voter;
    IRewardsDistributor internal _rewardsDistributor;
    IERC20 public _asset;
    IERC20 internal _aero;
    IERC20 public _lockedAsset;
    IAerodromeRouter internal _aeroRouter;
    address internal _aeroFactory;
    address public _vault;
    bool internal _paused;
    uint256 public _outstandingCapital;
    uint256 public  _multiplier; // rewards rate multiplier
    
    mapping(address => LoanInfo) public _loanDetails;
    mapping(address => bool) public _approvedPools;

    mapping(uint256 => uint256) public _rewardsPerEpoch;
    // ZeroBalanceOption enum to handle different scenarios when the loan balance is zero
    enum ZeroBalanceOption {
        DoNothing, // do nothing when the balance is zero
        InvestToVault, // invest the balance to the vault
        PayToOwner // pay the balance to the owner
    }

    // LoanInfo struct to store details about each loan
    struct LoanInfo {
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
        ZeroBalanceOption zeroBalanceOption;
        uint256 voteTimestamp;
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
    
    function initialize(address vault, address asset) initializer public {
        __Ownable_init(msg.sender); 
        __UUPSUpgradeable_init();
        address[] memory pools = new address[](1);
        pools[0] = 0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;
        _vault = vault;
        _voter = IXVoter(0x942117Ec0458a8AA08669E94B52001Bd43F889C1); // Linea voter 
        _rewardsDistributor = IRewardsDistributor(0x88a49cFCee0Ed5B176073DDE12186C4c922A9cD0);
        _asset = IERC20(asset);
        _aero = IERC20(0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348);
        _aeroRouter = IAerodromeRouter(0x85974429677c2a701af470B82F3118e74307826e);
        _aeroFactory = address(0xAe334f70A7FC44FCC2df9e6A37BC032497Cf80f1);
        _lockedAsset = IERC20(0xc93B315971A4f260875103F5DA84cB1E30f366Cc);
        _multiplier = 12;
    }


    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
