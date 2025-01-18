// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;

import "./interfaces/IVoter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "./interfaces/IAerodromeRouter.sol";
import {IRateCalculator} from "./interfaces/IRateCalculator.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {ICLGauge} from "./interfaces/ICLGauge.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

contract Loan is Ownable, ReentrancyGuard {
    // deployed contract addressed
    address dataFeedAddress =
        address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);
    IVoter public _voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    IRewardsDistributor public _rewardsDistributor =
        IRewardsDistributor(0x227f65131A261548b057215bB1D5Ab2997964C7d);
    address private _pool; // pool to vote on to receive fees
    IERC20 public _usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 public _aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IVotingEscrow private _ve =
        IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IAerodromeRouter private _aeroRouter =
        IAerodromeRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    address private _aeroFactory =
        address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IRateCalculator public _rateCalculator;

    address public _vault;

    bool public _paused;
    uint256 _outstandingCapital;
    AggregatorV3Interface internal _dataFeed;
    uint256 _multiplier = 8;

    mapping(uint256 => LoanInfo) public _loanDetails;
    mapping(address => bool) public _approvedTokens;

    mapping(uint256 => uint256) public _rewardsPerEpoch;
    uint256 public _lastEpochPaid;

    enum ZeroBalanceOption {
        DoNothing,
        InvestToVault,
        PayToOwner,
        ReturnNft,
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
    }

    address[] public _defaultPools;
    uint256[] public _defaultWeights;
    uint256 public _defaultPoolChangeTime;

    event CollateralAdded(uint256 tokenId, address owner);
    event CollateralWithdrawn(uint256 tokenId, address owner);
    event FundsBorrowed(uint256 tokenId, uint256 amount);

    constructor() Ownable(msg.sender) {
        address[] memory pools = new address[](1);
        pools[0] = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;

        _dataFeed = AggregatorV3Interface(dataFeedAddress);
        _defaultPoolChangeTime = block.timestamp;
    }

    function requestLoan(
        uint256 tokenId,
        uint256 amount,
        address[] calldata poolVotes
    ) public whenNotPaused {
        require(confirmUsdcPrice(), "Price of USDC is not $1");
        // require the msg.sender to be the owner of the token
        require(
            _ve.ownerOf(tokenId) == msg.sender,
            "Only the owner of the token can request a loan"
        );

        // ensure the token is locked permanently
        IVotingEscrow.LockedBalance memory lockedBalance = _ve.locked(tokenId);

        if (!lockedBalance.isPermanent) {
            if (lockedBalance.end <= block.timestamp) {
                revert("Token lock expired");
            }
            _ve.lockPermanent(tokenId);
        }

        _loanDetails[tokenId] = LoanInfo({
            balance: 0,
            borrower: msg.sender,
            timestamp: block.timestamp,
            outstandingCapital: 0,
            tokenId: tokenId,
            zeroBalanceOption: ZeroBalanceOption.DoNothing,
            pools: new address[](0),
            voteTimestamp: 0,
            claimTimestamp: 0
        });

        if (canVoteOnPool(tokenId)) {
            voteOnDefaultPool(tokenId);
        } else {
            uint256 usedWeights = _voter.usedWeights(tokenId);
            uint256 weights = 0;
            for (uint256 i = 0; i < poolVotes.length; i++) {
                uint256 weight = _voter.votes(tokenId, poolVotes[i]);
                weights += weight;
            }
            require(
                weights == usedWeights,
                "Weights must be equal to used weights"
            );
            _loanDetails[tokenId].pools = poolVotes;
        }

        if (amount > 0) {
            increaseLoan(tokenId, amount);
        }
        _ve.transferFrom(msg.sender, address(this), tokenId);

        emit CollateralAdded(tokenId, msg.sender);
    }

    function increaseLoan(
        uint256 tokenId,
        uint256 amount
    ) public whenNotPaused {
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
            loan.balance + amount <= maxLoan,
            "Cannot increase loan beyond max loan amount"
        );
        uint256 originationFee = (amount * 8) / 10000; // 0.8%
        loan.balance += amount + originationFee;
        loan.outstandingCapital += amount;
        _outstandingCapital += amount;
        _usdc.transferFrom(_vault, msg.sender, amount);
        emit FundsBorrowed(tokenId, amount);
    }

    function getRewards(uint256 tokenId) public returns (uint256 payment) {
        LoanInfo storage loan = _loanDetails[tokenId];
        address[] memory pools = loan.pools;
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
                    swapToToken(tokenBalance, tokens[i][j], address(asset));
                }
            }
        }
        uint256 assetBalancePost = asset.balanceOf(address(this));

        // calculate the amount of fees claimed
        payment = assetBalancePost - assetBalancePre;
    }

    function canVoteOnPool(uint256 tokenId) internal view returns (bool) {
        return _voter.lastVoted(tokenId) < ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    // swap paired token to usdc using aeroRouter
    function swapToToken(
        uint256 amountIn,
        address fromToken,
        address toToken
    ) internal returns (uint256 amountOut) {
        if (fromToken == toToken) {
            return amountIn;
        }
        IERC20(fromToken).approve(address(_aeroRouter), amountIn);
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](
            1
        );
        routes[0] = IAerodromeRouter.Route(
            address(fromToken),
            address(toToken),
            false,
            _aeroFactory
        );
        uint256[] memory returnAmounts = _aeroRouter.getAmountsOut(
            amountIn,
            routes
        );
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
        if (amount == 0) {
            LoanInfo storage loan = _loanDetails[tokenId];
            amount = loan.balance;
        }
        _usdc.transferFrom(msg.sender, address(this), amount);
        _pay(tokenId, amount);
    }

    function payMultiple(uint256[] memory tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            pay(tokenIds[0], 0);
        }
    }

    function _pay(uint256 tokenId, uint256 amount) internal {
        LoanInfo storage loan = _loanDetails[tokenId];
        if (amount == 0) {
            return;
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
        _usdc.transfer(_vault, amount);
        if (excess > 0) {
            _handleExcess(tokenId, excess);
        }
    }

    function _handleExcess(uint256 tokenId, uint256 excess) internal {
        LoanInfo storage loan = _loanDetails[tokenId];
        (
            uint256 protocolFeePercentage,
        ) = _rateCalculator.getInterestRate();
        uint256 protocolFee = (excess * protocolFeePercentage) / 10000;
        uint256 excessAfterFee = excess - protocolFee;
        _usdc.transfer(owner(), protocolFee);
        if (loan.zeroBalanceOption == ZeroBalanceOption.InvestToVault) {
            _usdc.approve(_vault, excessAfterFee);
            IERC4626(_vault).deposit(excessAfterFee, loan.borrower);
            return;
        }
        if (loan.zeroBalanceOption == ZeroBalanceOption.ReturnNft) {
            _usdc.transfer(loan.borrower, excessAfterFee);
            _ve.transferFrom(address(this), loan.borrower, tokenId);
            emit CollateralWithdrawn(tokenId, msg.sender);
            return;
        }
        _usdc.transfer(loan.borrower, excessAfterFee);
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

    function _claimRewards(uint256 tokenId) public {
        if (_rewardsDistributor.claimable(tokenId) > 0) {
            _rewardsDistributor.claim(tokenId);
        }

        LoanInfo storage loan = _loanDetails[tokenId];
        if(loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.DoNothing) {
            return;
        }

        uint256 amount = getRewards(tokenId);

        (
            uint256 protocolFeePercentage,
            uint256 lenderPremiumPercentage
        ) = _rateCalculator.getInterestRate();
        uint256 protocolFee = (amount * protocolFeePercentage) / 10000;
        loan.claimTimestamp = block.timestamp;

        if(loan.balance == 0 && loan.zeroBalanceOption == ZeroBalanceOption.ReinvestVeNft) {
            amount -= protocolFee;
            _aero.approve(address(_ve), amount);
            _ve.increaseAmount(tokenId, amount);
            _aero.transfer(owner(), protocolFee);
            return;
        }

        _usdc.transfer(owner(), protocolFee);
        uint256 lenderPremium = (amount * lenderPremiumPercentage) / 10000;
        _usdc.transfer(_vault, lenderPremium);
        recordRewards(lenderPremium);

        uint256 remaining = amount - protocolFee - lenderPremium;
        _pay(tokenId, remaining);
        if (loan.voteTimestamp < _defaultPoolChangeTime) {
            voteOnDefaultPool(tokenId);
        }
    }

    function voteOnDefaultPool(uint256 tokenId) internal {
        if(canVoteOnPool(tokenId)) {
            LoanInfo storage loan = _loanDetails[tokenId];
            _voter.vote(tokenId, _defaultPools, _defaultWeights);
            loan.voteTimestamp = block.timestamp;
            loan.pools = _defaultPools;
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

        // if rewards have not been claimed, claim them
        if(loan.claimTimestamp < ProtocolTimeLibrary.epochStart(block.timestamp)) {
            _claimRewards(tokenId);
        }

        _ve.transferFrom(address(this), loan.borrower, tokenId);
        emit CollateralWithdrawn(tokenId, msg.sender);
    }

    function getMaxLoan(
        uint256 tokenId
    ) public view returns (uint256, uint256) {
        // max amount loanable is the usdc in the vault
        uint256 veBalance = _ve.balanceOfNFTAt(tokenId, block.timestamp);
        uint256 rewardsRate = _rateCalculator.getRewardsRate();
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 10000) *
            _multiplier) / 1e12; // 0.0113 * veNFT balance of token
        uint256 maxLoan = maxLoanIgnoreSupply;
        uint256 vaultSupply = _usdc.balanceOf(_vault);
        if (maxLoan > vaultSupply) {
            maxLoan = vaultSupply;
        }
        return (maxLoan, maxLoanIgnoreSupply);
    }

    /* RESCUE FUNCTIONS */
    function rescueERC20(address token, uint256 amount) public onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /* VIEW FUNCTIONS */
    function getLoanDetails(
        uint256 tokenId
    ) public view returns (uint256 balance, address borrower) {
        LoanInfo storage loan = _loanDetails[tokenId];
        return (loan.balance, loan.borrower);
    }

    function activeAssets() public view returns (uint256) {
        return _outstandingCapital;
    }

    function lastEpochReward() public view returns (uint256) {
        return _rewardsPerEpoch[_lastEpochPaid];
    }

    /* MODIFIERS */
    modifier whenNotPaused() {
        require(!_paused, "Contract is paused");
        _;
    }

    function recordRewards(uint256 rewards) internal  {
        if (rewards > 0) {
            _rewardsPerEpoch[
                ProtocolTimeLibrary.epochStart(block.timestamp)
            ] += rewards;
            _lastEpochPaid = ProtocolTimeLibrary.epochStart(block.timestamp);
        }
    }

    /* OWNER FUNCTIONS */
    function setVault(address vault) public onlyOwner {
        if (_vault != address(0)) {
            revert("vault can only be set once");
        }
        _vault = vault;
    }

    function pause() public onlyOwner {
        _paused = true;
    }

    function unpause() public onlyOwner {
        _paused = false;
    }

    function getInterestRate() public view returns (uint256, uint256) {
        return _rateCalculator.getInterestRate();
    }

    function setRateCalculator(address rateCalculator) public onlyOwner {
        _rateCalculator = IRateCalculator(rateCalculator);

        (uint256 protocolFee, uint256 lenderPremium) = _rateCalculator
            .getInterestRate();
        require(
            protocolFee + lenderPremium <= 5000,
            "Sum of protocol fee and lender premium must be 50%"
        );
        require(
            protocolFee + lenderPremium > 0,
            "Sum of protocol fee and lender premium must be > 0%"
        );
        _rateCalculator.confirm();
    }

    function approveTokens(address[] calldata token) public onlyOwner {
        for (uint256 i = 0; i < token.length; i++) {
            _approvedTokens[token[i]] = true;
        }
    }

    function setDefaultPools(
        address[] memory pools,
        uint256[] memory weights
    ) public onlyOwner {
        // TODO: ensure weightd are 100%
        _defaultPools = pools;
        _defaultWeights = weights;
    }

    function setMultiplier(uint256 multiplier) public onlyOwner {
        _multiplier = multiplier;
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
    }
    
    /* ORACLE */
    function confirmUsdcPrice() internal view returns (bool) {
        (
            ,
            /* uint80 roundID */ int answer /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/,
            ,
            ,

        ) = _dataFeed.latestRoundData();

        // confirm price of usdc is $1
        return answer >= 99900000;
    }
}
