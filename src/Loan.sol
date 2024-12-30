// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;
import {console} from "forge-std/console.sol";
import "./interfaces/IVoter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "./interfaces/IAerodromeRouter.sol";
import { IRateCalculator } from "./interfaces/IRateCalculator.sol";

contract Loan is Ownable {
    // deployed contract addressed
    address dataFeedAddress = address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);
    IVoter public _voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address public _rewardsDistributor = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // USDC/WETH
    address private _pool; // pool to vote on to receive fees
    address private _asset; // USDC
    IERC20 private _pairedToken; // Paired token to USDC in the voted pool
    IVotingEscrow private _ve = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IAerodromeRouter private _aeroRouter = IAerodromeRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    address private _aeroFactory = address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IRateCalculator public rateCalculator;

    address public _vault;
    
    IERC20 public usdc;
    bool public paused;
    uint256 outstandingCapital;
    AggregatorV3Interface internal dataFeed;


    mapping(uint256 => LoanInfo) public _loanDetails;


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
    }

    // guages(pool)  (gauge to fees) (gauge to bribe)

    constructor(address _usdc,
        address pool) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        _asset = _usdc;
        _pool = pool;

        dataFeed = AggregatorV3Interface(dataFeedAddress);
    }


    function requestLoan(
        uint256 tokenId,
        uint256 amount
    ) public whenNotPaused {
        require(amount >  100, "Amount must be greater than 100");
        require(confirmUsdcPrice(), "Price of USDC is not $1");
        // require the msg.sender to be the owner of the token
        require(
            _ve.ownerOf(tokenId) == msg.sender,
            "Only the owner of the token can request a loan"
        );
        
        uint256 originationFee = amount * 8 / 10000; // 0.8%


        // ensure the token is locked permanently
        IVotingEscrow.LockedBalance memory lockedBalance = _ve.locked(tokenId);

        if (!lockedBalance.isPermanent) {
            if(lockedBalance.end <= block.timestamp) {
                revert("Token lock expired");
            }
            _ve.lockPermanent(tokenId);
        }

        _loanDetails[tokenId] = LoanInfo({
            balance: amount + originationFee,
            borrower: msg.sender,
            timestamp: block.timestamp,
            outstandingCapital: 0,
            tokenId: tokenId,
            zeroBalanceOption: ZeroBalanceOption.InvestToVault
        });

        increaseLoan(tokenId, amount);
        _ve.transferFrom(msg.sender, address(this), tokenId);
    }

    function increaseLoan(uint256 tokenId, uint256 amount) public whenNotPaused {
        address[] memory pools = new address[](1);
        pools[0] = _pool;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _voter.vote(tokenId, pools, amounts);

        // require(amount >  1e18, "Amount must be greater than $1");
        require(confirmUsdcPrice(), "Price of USDC is not $1");
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender, "Only the borrower can increase the loan");
        uint256 maxLoan = getMaxLoan(tokenId);
        require(loan.balance + amount <= maxLoan, "Cannot increase loan beyond max loan amount");
        uint256 originationFee = amount * 8 / 10000; // 0.8%
        loan.balance += amount + originationFee;
        loan.outstandingCapital += amount;
        outstandingCapital += amount;
        IERC20(usdc).transferFrom(_vault, msg.sender, amount);
    }


    function payMultiple(uint256[] memory tokenIds) public {
        for(uint256 i = 0; i < tokenIds.length; i++) {
            _pay(tokenIds[i], 0);
        }
    }
    

    // VENFT METHODS
    function getRewards(uint256 tokenId) public returns (uint256 payment) {
        address[] memory voters = new address[](1);
        voters[0] = address(_voter);

        // get beginning balance of token before claiming fees
        uint256 prebalanceAsset = IERC20(_asset).balanceOf(address(this));
        uint256 prebalanceToken = IERC20(0x4200000000000000000000000000000000000006).balanceOf(address(this));

        address[][] memory tokens = new address[][](2);
        address[] memory poolTokens = new address[](2);
        poolTokens[0] = address(0x4200000000000000000000000000000000000006);
        poolTokens[1] = address(0xA88594D404727625A9437C3f886C7643872296AE);
        address[] memory pool2Tokens = new address[](2);
        poolTokens[0] = address(0x4200000000000000000000000000000000000006);
        poolTokens[1] = address(0xA88594D404727625A9437C3f886C7643872296AE);
        
        tokens[0] = poolTokens;
        tokens[1] = pool2Tokens;

        address[] memory rewardsContract = new address[](2);
        rewardsContract[0] = address(0x4B27cA5Fd15CF4B9c27eac018f687B3eBF4809B9);
        rewardsContract[1] = address(0xd2eB3579b7c3C1536197aAb9df4A364Bb05Ec5D4);
        _voter.claimBribes(rewardsContract, tokens, tokenId);
        // swap paired token to usdc
        uint256 postBalanceToken = IERC20(0x4200000000000000000000000000000000000006).balanceOf(address(this));
        IERC20(0x4200000000000000000000000000000000000006).balanceOf(address(this));
        swapToUsdc(postBalanceToken-prebalanceToken, 0x4200000000000000000000000000000000000006);

        // get ending balance of token after claiming fees
        uint256 postBalanceAsset = IERC20(_asset).balanceOf(address(this));

        // calculate the amount of fees claimed
        payment = postBalanceAsset - prebalanceAsset;

    }

        // TODO to accept any token 
        //  function usedWeights(uint256 tokenId) external returns (uint256);
        // function poolVotes(uint256 tokenId, uint256 id) external returns (address[] memory);
        // function votes(uint256 tokenId, address pool) external returns (uint256);

//    // VENFT METHODS
//     function getRewards(uint256 tokenId, address[] memory rewards) public returns (uint256 payment) {
//         uint256 tokenBalancesPre = new uint256[](rewards.length);
//         uint256 assetBalancePre = IERC20(_asset).balanceOf(address(this));

//         address[][] memory rewardTokens = new address[][](rewards.length);
//         address[] memory tokens = new address[](rewards.length * 2);
//         mapping(address => uint256) memory tokenBalances = new mapping(address => uint256);
//         for (uint256 i = 0; i < rewards.length; i++) {
//             address[] memory rewardToken = new address[](2);
//             rewardToken[0] = ICLPool(rewards[i]).token0();
//             rewardToken[1] = ICLPool(rewards[i]).token1();
//             tokens[i] = rewardToken;
//             uint256 balance0 = IERC20(rewardToken[0]).balanceOf(address(this));
//             tokenBalances[rewardToken[0]] += balance0;
//             uint256 balance1 = IERC20(rewardToken[1]).balanceOf(address(this));
//             tokenBalances[rewardToken[1]] += balance1;
//         }

//         _voter.claimBribes(rewards, rewardTokens, tokenId);
//         // uint256 tokenBalancePost = IERC20(rewardTokens[j]).balanceOf(address(this));
//         // if(rewardTokens[j] != address(_asset)) {
//         //     swapToUsdc(tokenBalancePost-tokenBalancePre, rewardTokens[j]);
//         // }

//         uint256 assetBalancePost = IERC20(_asset).balanceOf(address(this));

//         // calculate the amount of fees claimed
//         payment = assetBalancePost - assetBalancePre;
//     }

    // swap paired token to usdc using aeroRouter
    function swapToUsdc(uint256 amountIn, address token) internal returns(uint256 amountOut)  {
        IERC20(token).approve(address(_aeroRouter),amountIn);
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route(address(token),_asset,false, _aeroFactory);
        uint256[] memory returnAmounts = _aeroRouter.getAmountsOut(amountIn,routes);
        uint256[] memory amounts = _aeroRouter.swapExactTokensForTokens(//swap usdc back to eth
            amountIn,
            returnAmounts[1],
            routes,
            address(this),
            block.timestamp
        ); 
        console.log("swapped %s to %s",amounts[0],amounts[1]);
        return amounts[0];
    }

// TODO LOAN GOES TO BALANCE/BORROWER PREMIUM/AND PROTOCOL FEE
// 75/20/5
    function pay(uint256 tokenId, uint256 amount) public {
        if(amount == 0) {
            amount = _getCurrentLoanBalance(tokenId);
        }
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        _pay(tokenId, amount);
    }

    function _pay(uint256 tokenId, uint256 amount) internal {
        LoanInfo storage loan = _loanDetails[tokenId];
        uint256 balance = _getCurrentLoanBalance(tokenId);
        uint256 excess = 0;
        if(amount == 0) {
            amount = loan.balance;
        }
        if(amount > balance) {
            amount = loan.balance;
            excess = amount - balance;
        }
        loan.balance -= amount;
        if(amount > loan.outstandingCapital) {
            outstandingCapital -= loan.outstandingCapital;
            loan.outstandingCapital = 0;
        } else {
            loan.outstandingCapital -= amount;
            outstandingCapital -= amount;
        }
        IERC20(usdc).transfer(_vault, amount);
        if(excess > 0) {
            IERC20(usdc).transfer(msg.sender, excess);
        }
    }

    function advance(uint256 tokenId) public {
        uint256 amount = getRewards(tokenId);

        LoanInfo storage loan = _loanDetails[tokenId];
        loan.balance = _getCurrentLoanBalance(tokenId);

        (uint256 protocolFeePercentage, uint256 lenderPremiumPercentage) = rateCalculator.getInterestRate();
        uint256 protocolFee = amount * protocolFeePercentage / 10000;
        uint256 lenderPremium = amount * lenderPremiumPercentage / 10000;
        uint256 remaining = amount - protocolFee - lenderPremium;

        IERC20(usdc).transfer(owner(), protocolFee);
        IERC20(usdc).transfer(_vault, protocolFee);
        _pay(tokenId, remaining);
    }

    // TODO CAN ALLOW ENTRY IF THEY ALREQDY VOTED FOR POOL
    // ALLOW ALL POOLS SWITCH IF NOT

    function advanceMultiple(uint256[] memory tokenIds) public {
        for(uint256 i = 0; i < tokenIds.length; i++) {
            advance(tokenIds[i]);
        }
    }   

    function claimCollateral(uint256 tokenId) public {
        LoanInfo storage loan = _loanDetails[tokenId];
        require(loan.borrower == msg.sender, "Only the borrower can claim collateral");
        if(loan.balance > 0) {
            revert("Cannot claim collateral while loan is active");
        }

        _ve.transferFrom(address(this), loan.borrower, tokenId);
    }


    function _getCurrentLoanBalance(uint256 tokenId) internal  view returns (uint256) {
        return _loanDetails[tokenId].balance;
    }

    function getMaxLoan(uint256 tokenId) public view returns (uint256) {
        // Max loan is max of USDC balance of _vault or 100 USDC or .0113 * veNFT balance of token * 8
        uint256 maxLoan = 1000e18;
        uint256 _vaultBalance = IERC20(_asset).balanceOf(_vault);
        if (_vaultBalance > maxLoan) {
            maxLoan = _vaultBalance;
        }

        uint256 veBalance = _ve.balanceOfNFTAt(tokenId, block.timestamp);
        uint256 veBalanceUSD = veBalance * 113 / 10000 * 8; // 0.0113 * veNFT balance of token
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
    function getLoanDetails(uint256 tokenId) public returns (uint256 balance, address borrower) {
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
        if(_vault != address(0)) {
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

        (uint256 protocolFee, uint256 lenderPremium) = rateCalculator.getInterestRate();
        require(protocolFee + lenderPremium <= 5000, "Sum of protocol fee and lender premium must be 50%");
        require(protocolFee + lenderPremium > 0, "Sum of protocol fee and lender premium must be 50%");
        rateCalculator.confirm();
    }

    /* USER METHODS */

    // vote on ppol only when balance is 0
    function votePool(address pool) public {
    }

    /* ORACLE */
    function confirmUsdcPrice() internal  returns (bool) {
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();

        // confirm price of usdc is $1
        return answer  >= 99900000;
    }
}
