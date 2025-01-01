// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;
import {console} from "forge-std/console.sol";
import "./interfaces/IVoter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "./interfaces/IAerodromeRouter.sol";
import {IRateCalculator} from "./interfaces/IRateCalculator.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {ICLGauge} from "./interfaces/ICLGauge.sol";

contract Loan is Ownable {
    // deployed contract addressed
    address dataFeedAddress =
        address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);
    IVoter public _voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    IRewardsDistributor public _rewardsDistributor =
        IRewardsDistributor(0x227f65131A261548b057215bB1D5Ab2997964C7d);
    address private _pool; // pool to vote on to receive fees
    IERC20 public usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 private _pairedToken; // Paired token to USDC in the voted pool
    IVotingEscrow private _ve =
        IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IAerodromeRouter private _aeroRouter =
        IAerodromeRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    address private _aeroFactory =
        address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IRateCalculator public rateCalculator;

    address public _vault;

    bool public paused;
    uint256 outstandingCapital;
    AggregatorV3Interface internal dataFeed;
    uint256 multiplier = 8;

    mapping(uint256 => LoanInfo) public _loanDetails;
    mapping(address => bool) public _approvedTokens;

    enum ZeroBalanceOption {
        PayToOwner,
        ReinvestVeNft,
        InvestToVault
    }

    struct LoanInfo {
        uint256 tokenId;
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
        ZeroBalanceOption zeroBalanceOption;
        address[] pools;
        uint256[] weights;
        bool votedOnDefaultPool;
    }

    address[] public defaultPools;
    uint256[] public defaultWeights;

    constructor() Ownable(msg.sender) {
        address[] memory pools = new address[](1);
        pools[0] = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
        defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        defaultWeights = amounts;

        dataFeed = AggregatorV3Interface(dataFeedAddress);
    }

    function requestLoan(uint256 tokenId, uint256 amount) public whenNotPaused {
        require(confirmUsdcPrice(), "Price of USDC is not $1");
        // require the msg.sender to be the owner of the token
        require(
            _ve.ownerOf(tokenId) == msg.sender,
            "Only the owner of the token can request a loan"
        );

        uint256 originationFee = (amount * 8) / 10000; // 0.8%

        // ensure the token is locked permanently
        IVotingEscrow.LockedBalance memory lockedBalance = _ve.locked(tokenId);

        if (!lockedBalance.isPermanent) {
            if (lockedBalance.end <= block.timestamp) {
                revert("Token lock expired");
            }
            _ve.lockPermanent(tokenId);
        }

        bytes4 selector = bytes4(
            keccak256("vote(uint256,address[],uint256[])")
        );
        bytes memory data = abi.encodeWithSelector(
            selector,
            tokenId,
            defaultPools,
            defaultWeights
        );

        (bool success, bytes memory returnData) = address(_voter).call(data);

        _loanDetails[tokenId] = LoanInfo({
            balance: amount + originationFee,
            borrower: msg.sender,
            timestamp: block.timestamp,
            outstandingCapital: 0,
            tokenId: tokenId,
            zeroBalanceOption: ZeroBalanceOption.InvestToVault,
            votedOnDefaultPool: success,
            pools: new address[](0),
            weights: new uint256[](0)
        });

        if (success) {
            _loanDetails[tokenId].pools = defaultPools;
            _loanDetails[tokenId].weights = defaultWeights;
        }

        // try to vote on pool
        if(amount > 0) {
            increaseLoan(tokenId, amount);
        }
        _ve.transferFrom(msg.sender, address(this), tokenId);
    }

    function increaseLoan(
        uint256 tokenId,
        uint256 amount
    ) public whenNotPaused {
        require(confirmUsdcPrice(), "Price of USDC is not $1");
        require(amount > 1e6, "Amount must be greater than 1 cent");
        LoanInfo storage loan = _loanDetails[tokenId];

        if (!loan.votedOnDefaultPool) {
            bytes4 selector = bytes4(
                keccak256("vote(uint256,address[],uint256[])")
            );
            bytes memory data = abi.encodeWithSelector(
                selector,
                tokenId,
                defaultPools,
                defaultWeights
            );

            (bool success, bytes memory returnData) = address(_voter).call(
                data
            );
            if (success) {
                loan.pools = defaultPools;
                loan.weights = defaultWeights;
            }
        }

        require(amount >  1e18, "Amount must be greater than $1");
        require(
            loan.borrower == msg.sender,
            "Only the borrower can increase the loan"
        );
        uint256 maxLoan = getMaxLoan(tokenId);
        require(
            loan.balance + amount <= maxLoan,
            "Cannot increase loan beyond max loan amount"
        );
        uint256 originationFee = (amount * 8) / 10000; // 0.8%
        loan.balance += amount + originationFee;
        loan.outstandingCapital += amount;
        outstandingCapital += amount;
        usdc.transferFrom(_vault, msg.sender, amount);
    }

    function payMultiple(uint256[] memory tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _pay(tokenIds[i], 0);
        }
    }
    function getRewards(uint256 tokenId) public returns (uint256 payment) {
        LoanInfo storage loan = _loanDetails[tokenId];
        address[] memory pools = loan.pools;
        require(msg.sender==tx.origin, "No Contracts allowed.");
        uint256 assetBalancePre = usdc.balanceOf(address(this));
        address[][] memory tokens = new address[][](2);
        address[] memory rewards = new address[](2);
        console.log("pools %s", pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            address[] memory token = new address[](2);
            address gauge = _voter.gauges(pools[i]);
            rewards[0] = _voter.gaugeToFees(gauge);
            rewards[1] = _voter.gaugeToBribe(gauge);
            console.log("rewards %s", rewards[0]);
            token[0] = ICLGauge(address(pools[0])).token0();
            token[1] = ICLGauge(address(pools[0])).token1();
            tokens[0] = token;
            tokens[1] = token;
            console.log("token0  %s", token[0]);
            console.log("token1  %s", token[1]);
            _voter.claimFees(rewards, tokens, tokenId);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
                if (tokens[i][j] != address(usdc)) {
                    uint256 tokenBalance = IERC20(tokens[i][j]).balanceOf(
                        address(this)
                    );
                    if (tokenBalance > 0) {
                        swapToUsdc(tokenBalance, tokens[i][j]);
                    }
                }
            }
        }
        uint256 assetBalancePost = usdc.balanceOf(address(this));

        console.log("assetBalancePre %s", assetBalancePre);
        console.log("assetBalancePost %s", assetBalancePost);
        // calculate the amount of fees claimed
        payment = assetBalancePost - assetBalancePre;
        console.log("payment %s", payment);
    }

    // swap paired token to usdc using aeroRouter
    function swapToUsdc(
        uint256 amountIn,
        address token
    ) internal returns (uint256 amountOut) {
        IERC20(token).approve(address(_aeroRouter), amountIn);
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](
            1
        );
        routes[0] = IAerodromeRouter.Route(
            address(token),
            address(usdc),
            false,
            _aeroFactory
        );
        uint256[] memory returnAmounts = _aeroRouter.getAmountsOut(
            amountIn,
            routes
        );
        uint256[] memory amounts = _aeroRouter.swapExactTokensForTokens( //swap usdc back to eth
                amountIn,
                returnAmounts[1],
                routes,
                address(this),
                block.timestamp
            );
        console.log("swapped %s %s to %s", token, amounts[0], amounts[1]);
        return amounts[0];
    }

    // TODO LOAN GOES TO BALANCE/BORROWER PREMIUM/AND PROTOCOL FEE
    // 75/20/5
    function pay(uint256 tokenId, uint256 amount) public {
        if (amount == 0) {
            amount = _getCurrentLoanBalance(tokenId);
        }
        usdc.transferFrom(msg.sender, address(this), amount);
        _pay(tokenId, amount);
    }

    function _pay(uint256 tokenId, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        LoanInfo storage loan = _loanDetails[tokenId];
        uint256 balance = _getCurrentLoanBalance(tokenId);
        uint256 excess = 0;
        if (amount > balance) {
            amount = loan.balance;
            excess = amount - balance;
        }
        loan.balance -= amount;
        if (amount > loan.outstandingCapital) {
            outstandingCapital -= loan.outstandingCapital;
            loan.outstandingCapital = 0;
        } else {
            loan.outstandingCapital -= amount;
            outstandingCapital -= amount;
        }
        usdc.transfer(_vault, amount);
        if (excess > 0) {
            usdc.transfer(msg.sender, excess);
        }
    }

    function advance(uint256 tokenId) public {
        _rewardsDistributor.claim(tokenId);

        LoanInfo storage loan = _loanDetails[tokenId];
        if (!loan.votedOnDefaultPool) {
            _voter.vote(tokenId, defaultPools, defaultWeights);
        }

        loan.balance = _getCurrentLoanBalance(tokenId);
        uint256 amount = getRewards(tokenId);

        (
            uint256 protocolFeePercentage,
            uint256 lenderPremiumPercentage
        ) = rateCalculator.getInterestRate();
        uint256 protocolFee = (amount * protocolFeePercentage) / 10000;
        uint256 lenderPremium = (amount * lenderPremiumPercentage) / 10000;
        uint256 remaining = amount - protocolFee - lenderPremium;

        usdc.transfer(owner(), protocolFee);
        usdc.transfer(_vault, protocolFee);
        _pay(tokenId, remaining);
    }

    // TODO CAN ALLOW ENTRY IF THEY ALREQDY VOTED FOR POOL
    // ALLOW ALL POOLS SWITCH IF NOT

    function advanceMultiple(uint256[] memory tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            advance(tokenIds[i]);
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
    }

    function _getCurrentLoanBalance(
        uint256 tokenId
    ) internal view returns (uint256) {
        return _loanDetails[tokenId].balance;
    }

    function getMaxLoan(uint256 tokenId) public view returns (uint256) {
        // max amount loanable is the usdc in the vault
        uint256 maxLoan = usdc.balanceOf(_vault);

        uint256 veBalance = _ve.balanceOfNFTAt(tokenId, block.timestamp);
        uint256 veBalanceUSD = ((veBalance * 113) / 10000) * multiplier; // 0.0113 * veNFT balance of token
        if (veBalanceUSD < maxLoan) {
            maxLoan = veBalanceUSD;
        }
        return maxLoan;
    }

    /* RESCUE FUNCTIONS */
    function rescueERC20(address token, uint256 amount) public onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /* VIEW FUNCTIONS */
    function getLoanDetails(
        uint256 tokenId
    ) public returns (uint256 balance, address borrower) {
        LoanInfo storage loan = _loanDetails[tokenId];
        loan.balance = _getCurrentLoanBalance(tokenId);
        return (loan.balance, loan.borrower);
    }

    function activeAssets() public view returns (uint256) {
        return outstandingCapital;
    }

    /* MODIFIERS */
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    /* OWNER FUNCTIONS */
    function setVault(address vault) public onlyOwner {
        if (_vault != address(0)) {
            revert("vault can only be set once");
        }
        _vault = vault;
    }

    function pause() public onlyOwner {
        paused = true;
    }

    function unpause() public onlyOwner {
        paused = false;
    }

    function getAllNfts() external returns (address[] memory) {
        address[] memory nfts = new address[](1);
        nfts[0] = address(0x0);
        return nfts;
    }

    function getInterestRate() public view returns (uint256, uint256) {
        return rateCalculator.getInterestRate();
    }

    function setRateCalculator(address _rateCalculator) public onlyOwner {
        rateCalculator = IRateCalculator(_rateCalculator);

        (uint256 protocolFee, uint256 lenderPremium) = rateCalculator
            .getInterestRate();
        require(
            protocolFee + lenderPremium <= 5000,
            "Sum of protocol fee and lender premium must be 50%"
        );
        require(
            protocolFee + lenderPremium > 0,
            "Sum of protocol fee and lender premium must be > 0%"
        );
        rateCalculator.confirm();
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
        defaultPools = pools;
        defaultWeights = weights;
    }


    function setMultiplier(uint256 _multiplier) public onlyOwner {
        multiplier = _multiplier;
    }

    /* USER METHODS */

    // vote on ppol only when balance is 0
    function votePool(address pool) public {}

    /* ORACLE */
    function confirmUsdcPrice() internal returns (bool) {
        (
            ,
            /* uint80 roundID */ int answer,
            ,
            ,

        ) = /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            dataFeed.latestRoundData();

        // confirm price of usdc is $1
        return answer >= 99900000;
    }
}
