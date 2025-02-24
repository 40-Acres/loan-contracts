// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;

import "./interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {ICLGauge} from "./interfaces/ICLGauge.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {RateStorage} from "./RateStorage.sol";
import {LoanStorage} from "./LoanStorage.sol";
import {IAerodromeRouter} from "./interfaces/IAerodromeRouter.sol";
import {IRouter} from "./interfaces/IRouter.sol";

contract Loan is ReentrancyGuard, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, RateStorage, LoanStorage {
    // deployed contract addressed
    IVoter internal _voter;
    IRewardsDistributor internal _rewardsDistributor;
    address public _pool; // pool to vote on to receive fees
    IERC20 internal _usdc;
    IERC20 internal _aero;
    IVotingEscrow internal _ve;
    IAerodromeRouter internal _aeroRouter;
    address internal _aeroFactory;
    address internal _rateCalculator; // deprecated
    address public _vault;

    bool public _paused;
    uint256 public _outstandingCapital;
    uint256 public  _multiplier;

    mapping(uint256 => LoanInfo) public _loanDetails;
    mapping(address => bool) public _approvedTokens; // deprecated

    mapping(uint256 => uint256) public _rewardsPerEpoch;
    uint256 public _lastEpochPaid; // deprecated

    
    enum ZeroBalanceOption {
        DoNothing,
        InvestToVault,
        PayToOwner,
        ReinvestVeNft
    }

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
    }

    address[] public _defaultPools;
    uint256[] public _defaultWeights;
    uint256 public _defaultPoolChangeTime;

    
    event CollateralAdded(uint256 tokenId, address owner, ZeroBalanceOption option);
    event ZeroBalanceOptionSet(uint256 tokenId, ZeroBalanceOption option);
    event CollateralWithdrawn(uint256 tokenId, address owner);
    event FundsBorrowed(uint256 tokenId, address owner, uint256 amount);
    event RewardsReceived(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    event RewardsInvested(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);


    constructor() {
        _disableInitializers();
    }

    function initialize(address vault) initializer virtual public {
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
        _usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        _aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
        _ve = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
        _aeroRouter = IAerodromeRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
        _aeroFactory = address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function requestLoan(
        uint256 tokenId,
        uint256 amount,
        ZeroBalanceOption zeroBalanceOption
    ) public whenNotPaused {
        require(confirmUsdcPrice(), "Price of USDC is not $1");
        // require the msg.sender to be the owner of the token
        require(
            _ve.ownerOf(tokenId) == msg.sender,
            "Only the owner of the token can request a loan"
        );


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
            weight: _ve.balanceOfNFTAt(tokenId, block.timestamp),
            unpaidFees: 0
        });

        if (canVoteOnPool(tokenId)) {
            voteOnDefaultPool(tokenId);
        }

        
        _ve.transferFrom(msg.sender, address(this), tokenId);
        require(_ve.ownerOf(tokenId) == address(this), "Token not locked");

        // ensure the token is locked permanently
        IVotingEscrow.LockedBalance memory lockedBalance = _ve.locked(tokenId);
        if (!lockedBalance.isPermanent) {
            if (lockedBalance.end <= block.timestamp) {
                revert("Token lock expired");
            }
            _ve.lockPermanent(tokenId);
        }

        emit CollateralAdded(tokenId, msg.sender, zeroBalanceOption);
        addTotalWeight(_loanDetails[tokenId].weight);

        if (amount > 0) {
            increaseLoan(tokenId, amount);
        }
    }

    function increaseLoan(
        uint256 tokenId,
        uint256 amount
    ) public whenNotPaused {
        require(amount > .01e6, "Amount must be greater than .01 USDC");
        require(_ve.ownerOf(tokenId) == address(this), "Token not locked");
        require(confirmUsdcPrice(), "Price of USDC is not $1");
        LoanInfo storage loan = _loanDetails[tokenId];

        if (loan.voteTimestamp < _defaultPoolChangeTime) {
            voteOnDefaultPool(tokenId);
        }

        require(
            loan.borrower == msg.sender,
            "Only the borrower can increase the loan"
        );
        (uint256 maxLoan, ) = getMaxLoan(tokenId);
        require(
            amount <= maxLoan,
            "Cannot increase loan beyond max loan amount"
        );
        uint256 originationFee = (amount * 80) / 10000; // 0.8%
        loan.unpaidFees += originationFee;
        loan.balance += amount + originationFee;
        loan.outstandingCapital += amount;
        _outstandingCapital += amount;
        require(_usdc.transferFrom(_vault, msg.sender, amount));
        emit FundsBorrowed(tokenId, loan.borrower, amount);
    }

    function getRewards(uint256 tokenId, address[] memory pools) internal returns (uint256 payment) {
        LoanInfo storage loan = _loanDetails[tokenId];
        IERC20 asset;
        if(loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.ReinvestVeNft) {
            asset = _aero;
        } else {
            asset = _usdc;
        }
        uint256 assetBalancePre = asset.balanceOf(address(this));
        address[][] memory tokens = new address[][](2);
        address[] memory rewards = new address[](2);
        for (uint256 i = 0; i < pools.length; i++) {
            address[] memory token = new address[](2);
            address gauge = _voter.gauges(pools[i]);
            rewards[0] = _voter.gaugeToFees(gauge);
            rewards[1] = _voter.gaugeToBribe(gauge);
            token[0] = ICLGauge(address(pools[0])).token0();
            token[1] = ICLGauge(address(pools[0])).token1();
            tokens[0] = token;
            tokens[1] = token;
            _voter.claimFees(rewards, tokens, tokenId);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
                uint256 tokenBalance = IERC20(tokens[i][j]).balanceOf(
                    address(this)
                );
                if(tokenBalance > 0) {
                    swapToToken(tokenBalance, tokens[i][j], address(asset), loan.borrower);
                }
            }
        }
        uint256 assetBalancePost = asset.balanceOf(address(this));

        // calculate the amount of fees claimed
        payment = assetBalancePost - assetBalancePre;
    }


    function canVoteOnPool(uint256 tokenId) internal virtual view returns (bool) {
        return _voter.lastVoted(tokenId) < ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    // swap paired token to usdc using aeroRouter
    function swapToToken(
        uint256 amountIn,
        address fromToken,
        address toToken,
        address borrower
    ) internal returns (uint256 amountOut) {
        if (fromToken == toToken || amountIn == 0) {
            return amountIn;
        }
        IERC20(fromToken).approve(address(_aeroRouter), amountIn);
        IRouter.Route[] memory routes = new IRouter.Route[](
            1
        );
        routes[0] = IRouter.Route(
            address(fromToken),
            address(toToken),
            false,
            _aeroFactory
        );
        uint256[] memory returnAmounts = _aeroRouter.getAmountsOut(
            amountIn,
            routes
        );
        if (returnAmounts[1] == 0) {
            // send to borrower
            require(IERC20(fromToken).transfer(borrower, amountIn));
            return 0;
        }
        uint256[] memory amounts = _aeroRouter.swapExactTokensForTokens(
                amountIn,
                returnAmounts[1],
                routes,
                address(this),
                block.timestamp
            );
        return amounts[0];
    }

    function pay(uint256 tokenId, uint256 amount) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        if (amount == 0) {
            amount = loan.balance;
        }

        require(_usdc.transferFrom(msg.sender, address(this), amount));
        _pay(tokenId, amount);
    }

    function payMultiple(uint256[] memory tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            pay(tokenIds[i], 0);
        }
    }

    function _pay(uint256 tokenId, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        LoanInfo storage loan = _loanDetails[tokenId];

        // take out any fees first
        if(loan.unpaidFees > 0) {
            uint256 feesPaid = loan.unpaidFees;
            if(feesPaid > amount) {
                feesPaid = amount;
            }
            amount -= feesPaid;
            loan.unpaidFees -= feesPaid;
            loan.balance -= feesPaid;
            require(_usdc.transfer(_vault, feesPaid));
            recordRewards(feesPaid);
            emit RewardsReceived(ProtocolTimeLibrary.epochStart(block.timestamp), feesPaid, loan.borrower, tokenId);
            if(amount == 0) {
                return;
            }
        }

        uint256 excess = 0;
        if (amount > loan.balance) {
            excess = amount - loan.balance;
            amount = loan.balance;
        }
        loan.balance -= amount;
        if (amount > loan.outstandingCapital) {
            _outstandingCapital -= loan.outstandingCapital;
            loan.outstandingCapital = 0;
        } else {
            loan.outstandingCapital -= amount;
            _outstandingCapital -= amount;
        }


        require(_usdc.transfer(_vault, amount));
        if (excess > 0) {
            handleZeroBalance(tokenId, amount, false);
        }
    }
    
    function claimRewards(uint256 tokenId) public nonReentrant  {
        _claimRewards(tokenId);
    }

    function claimRewardsMultiple(
        uint256[] memory tokenIds
    ) public nonReentrant  {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimRewards(tokenIds[i]);
        }
    }

    function _claimRewards(uint256 tokenId) internal {
        LoanInfo storage loan = _loanDetails[tokenId];
        // if weight of loan is 0, populate it
        if (loan.weight == 0) {
            loan.weight = _ve.balanceOfNFTAt(tokenId, block.timestamp);
            addTotalWeight(loan.weight);
        }
        if(loan.borrower == address(0) || _ve.ownerOf(tokenId) != address(this)) {
            return;
        }
        
        if (loan.voteTimestamp < _defaultPoolChangeTime) {
            voteOnDefaultPool(tokenId);
        }
        
        uint256 claimable = _rewardsDistributor.claimable(tokenId);
        if (claimable > 0) {
            try _rewardsDistributor.claim(tokenId) {
                addTotalWeight(claimable);
                loan.weight += claimable;
            } catch {
                // unable to claim
            }
        }


        if(loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.DoNothing) {
            return;
        }

        address[] memory pools = loan.pools;
        if(pools.length == 0) {
            pools = _defaultPools;
        }
        uint256 amount = getRewards(tokenId, pools);
        if(amount  > 0 && loan.voteTimestamp > _defaultPoolChangeTime) {
            updateActualRewardsRate(amount, loan.weight);
        }

        loan.claimTimestamp = block.timestamp;
        // handleZeroBalance
        if(loan.balance == 0) {
            handleZeroBalance(tokenId, amount, true);
            return;
        } 

        uint256 protocolFeePercentage = getProtocolFee();
        uint256 lenderPremiumPercentage = getLenderPremium();
        uint256 protocolFee = (amount * protocolFeePercentage) / 10000;
        require(_usdc.transfer(owner(), protocolFee));
        uint256 lenderPremium = (amount * lenderPremiumPercentage) / 10000;
        if(lenderPremium > 0) {
            require(_usdc.transfer(_vault, lenderPremium));
            recordRewards(lenderPremium);
            emit RewardsReceived(ProtocolTimeLibrary.epochStart(block.timestamp), lenderPremium, loan.borrower, tokenId);
        }

        uint256 remaining = amount - protocolFee - lenderPremium;
        _pay(tokenId, remaining);

    }

    function updateActualRewardsRate(uint256 rewards, uint256 weight) internal {
        uint256 relayRate = (rewards * 1e18) / (weight / 1e12);
        setActualRewardsRate(relayRate);
    }

    function handleZeroBalance(uint256 tokenId, uint256 amount, bool takeFees) internal {
        LoanInfo storage loan = _loanDetails[tokenId];
        if(loan.zeroBalanceOption == ZeroBalanceOption.ReinvestVeNft) {
            if(takeFees) {
                uint256 zeroBalanceFee = (amount * getZeroBalanceFee()) / 10000;
                amount -= zeroBalanceFee;
                require(_usdc.transfer(owner(), zeroBalanceFee));
            }
            _aero.approve(address(_ve), amount);
            _ve.increaseAmount(tokenId, amount);
            return;
        }
        if (loan.zeroBalanceOption == ZeroBalanceOption.InvestToVault) {
            _usdc.approve(_vault, amount);
            IERC4626(_vault).deposit(amount, loan.borrower);
            emit RewardsInvested(ProtocolTimeLibrary.epochStart(block.timestamp), amount, loan.borrower, tokenId);
            return;
        }
        if(loan.zeroBalanceOption == ZeroBalanceOption.PayToOwner) {
            if(takeFees) {
                uint256 zeroBalanceFee = (amount * getZeroBalanceFee()) / 10000;
                amount -= zeroBalanceFee;
                require(_usdc.transfer(owner(), zeroBalanceFee));
            }
            require(_usdc.transfer(loan.borrower, amount));
            return;
        }
        return;
    }

    function claimBribes(uint256 tokenId, address[] calldata pools) public nonReentrant {
        LoanInfo storage loan = _loanDetails[tokenId];
        if(loan.borrower == address(0) || _ve.ownerOf(tokenId) != address(this)) {
            return;
        }

        if (loan.voteTimestamp < _defaultPoolChangeTime) {
            voteOnDefaultPool(tokenId);
        }

        if(loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.DoNothing) {
            return;
        }

        uint256 amount = getRewards(tokenId, pools);
        if(amount == 0) {
            return;
        }

        uint256 protocolFeePercentage = getProtocolFee();
        uint256 lenderPremiumPercentage = getLenderPremium();
        uint256 protocolFee = (amount * protocolFeePercentage) / 10000;
        loan.claimTimestamp = block.timestamp;

        if(loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.ReinvestVeNft) {
            uint256 zeroBalanceFee = (amount * getZeroBalanceFee()) / 10000;
            amount -= zeroBalanceFee;
            _aero.approve(address(_ve), amount);
            _ve.increaseAmount(tokenId, amount);
            require(_aero.transfer(owner(), zeroBalanceFee));
            return;
        }

        require(_usdc.transfer(owner(), protocolFee));
        uint256 lenderPremium = (amount * lenderPremiumPercentage) / 10000;
        require(_usdc.transfer(_vault, lenderPremium));
        recordRewards(lenderPremium);
        emit RewardsReceived(ProtocolTimeLibrary.epochStart(block.timestamp), lenderPremium, loan.borrower, tokenId);

        uint256 remaining = amount - protocolFee - lenderPremium;
        _pay(tokenId, remaining);
        

    }

    function voteOnDefaultPool(uint256 tokenId) public {
        if(canVoteOnPool(tokenId)) {
            LoanInfo storage loan = _loanDetails[tokenId];
            try _voter.vote(tokenId, _defaultPools, _defaultWeights) {
                loan.voteTimestamp = block.timestamp;
                loan.pools = _defaultPools;
            } catch {
                // unable to vote
            }
        }
    }

    function claimCollateral(uint256 tokenId) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(
            loan.borrower == msg.sender,
            "Only the borrower can claim collateral"
        );
        if (loan.balance > 0) {
            revert("Cannot claim collateral while loan is active");
        }

        _ve.transferFrom(address(this), loan.borrower, tokenId);
        emit CollateralWithdrawn(tokenId, msg.sender);
        subTotalWeight(loan.weight);
        delete _loanDetails[tokenId];
    }

    function getMaxLoan(
        uint256 tokenId
    ) public view returns (uint256, uint256) {
        // max amount loanable is the usdc in the vault
        uint256 veBalance = _ve.balanceOfNFTAt(tokenId, block.timestamp);
        uint256 rewardsRate =  getRewardsRate();
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) *
            _multiplier) / 1e12; // rewardsRate * veNFT balance of token
        uint256 maxLoan = maxLoanIgnoreSupply;

        // max utilization ratio is 80%
        uint256 vaultBalance = _usdc.balanceOf(_vault);
        uint256 vaultSupply =  vaultBalance + _outstandingCapital;
        uint256 maxUtilization = (vaultSupply * 8000) / 10000;

        // if the vault is over utilized, no loans can be made
        if(_outstandingCapital > maxUtilization) {
            return (0, maxLoanIgnoreSupply);
        }


        LoanInfo storage loan = _loanDetails[tokenId];
        if(loan.balance > maxLoan) {
            return (0, maxLoanIgnoreSupply);
        }

        maxLoan = maxLoan - loan.balance;

        // can only loan up to the max utilization amount
        uint256 vaultAvailableSupply = maxUtilization - _outstandingCapital;
        if (maxLoan > vaultAvailableSupply) {
            maxLoan = vaultAvailableSupply;
        }

        if (maxLoan > vaultBalance) {
            maxLoan = vaultBalance;
        }

        return (maxLoan, maxLoanIgnoreSupply);
    }

    function recordRewards(uint256 rewards) internal  {
        if (rewards > 0) {
            _rewardsPerEpoch[
                ProtocolTimeLibrary.epochStart(block.timestamp)
            ] += rewards;
        }
    }

    /* Rate Methods */
    function getZeroBalanceFee() public view override returns (uint256) {
        uint256 zeroBalanceFee = RateStorage.getZeroBalanceFee();
        if (zeroBalanceFee == 0) {
            return 100; // 1%
        }
        return zeroBalanceFee;
    }

    function getRewardsRate() public view override returns (uint256) {
        uint256 rewardsRate = RateStorage.getRewardsRate();
        if (rewardsRate == 0) {
            return 113; 
        }
        return rewardsRate;
    }

    function getLenderPremium() public view override returns (uint256) {
        uint256 lenderPremium = RateStorage.getLenderPremium();
        if (lenderPremium == 0) {
            return 2000; // 20%
        }
        return lenderPremium;
    }

    function getProtocolFee() public view override returns (uint256) {
        uint256 protocolFee = RateStorage.getProtocolFee();
        if (protocolFee == 0) {
            return  500;  // 5%
        }
        return protocolFee;
    }

    /* VIEW FUNCTIONS */
    function getLoanDetails(
        uint256 tokenId
    ) public view returns (uint256 balance, address borrower, address[] memory pools) {
        LoanInfo storage loan = _loanDetails[tokenId];
        return (loan.balance, loan.borrower, loan.pools);
    }

    function activeAssets() public view returns (uint256) {
        return _outstandingCapital;
    }

    function lastEpochReward() public view returns (uint256) {
        return _rewardsPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    /* MODIFIERS */
    modifier whenNotPaused() {
        require(!_paused, "Contract is paused");
        _;
    }

    /* OWNER METHODS */

    function pause() public onlyOwner {
        _paused = true;
    }

    function unpause() public onlyOwner {
        _paused = false;
    }

    function setDefaultPools(
        address[] memory pools,
        uint256[] memory weights
    ) public onlyOwner {
        _defaultPools = pools;
        _defaultWeights = weights;
        _defaultPoolChangeTime = block.timestamp;
    }

    function setMultiplier(uint256 multiplier) public onlyOwner {
        _multiplier = multiplier;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Cannot renounce ownership");
    }

    /* RESCUE FUNCTIONS */
    function rescueERC20(address token, uint256 amount) public onlyOwner {
        require(IERC20(token).transfer(owner(), amount));
    }

    /* USER METHODS */
    function setZeroBalanceOption(
        uint256 tokenId,
        ZeroBalanceOption option
    ) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(
            loan.borrower == msg.sender,
            "Only the borrower can set the zero balance option"
        );
        loan.zeroBalanceOption = option;
        emit ZeroBalanceOptionSet(tokenId, option);
    }
    
    /* ORACLE */
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

}
