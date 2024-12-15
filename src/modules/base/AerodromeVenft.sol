pragma solidity ^0.8.28;

import {IVoter} from "../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "../../interfaces/IAerodromeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../../libraries/LoanLibrary.sol";

// VOTER = 0x16613524e02ad97edfef371bc883f2f5d6c480a5 
// VOTING ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4
// AERODROME/USDC = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d
// REWARDS DISTRIBUTOR = 0x227f65131a261548b057215bb1d5ab2997964c7d

contract AerodromeVenft {
    using LoanLibrary for LoanLibrary.LoanInfo;

    IVoter public voter;
    address public votingRewards = 0x14df87824a11DC27afF185D3149E05aaa4735f60; // USDC/WETH
    address public protocol = address(0x1);
    address public provider = address(0x2);
    address private pool; // pool to vote on to receive fees
    address private usdc; // USDC
    IERC20 private pairedToken; // Paired token to USDC in the voted pool
    address private parent; // parent contract
    IERC20 private aeroToken = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IVotingEscrow private ve;
    IAerodromeRouter private aeroRouter = IAerodromeRouter(0x9c7305eb78a432ced5C4D14Cac27E8Ed569A2e26);
    address private aeroFactory = address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);

    uint256 public protocolFeePercentage = 25; // 25% of interest rates
    uint256 public lenderFeePercentage = 75; // 75% fee goes to lender

    mapping(uint256 => LoanLibrary.LoanInfo) private _loans;

    constructor(
        address _token0,
        address _pool,
        address _parent,
        address _votingEscrow,
        address _voter
    ) {
        ve = IVotingEscrow(_votingEscrow);
        voter = IVoter(_voter);
        usdc = _token0;
        pool = _pool;
        parent = _parent;
    }

    function create(
        address _token,
        uint256 _tokenId,
        uint256 _loanAmount,
        address _borrower
    ) external {
        // create a loan
        //.09% generation fee

        LoanLibrary.LoanInfo memory loan = LoanLibrary.LoanInfo({
            tokenAddress: _token,
            tokenId: _tokenId,
            balance: _loanAmount + (_loanAmount * 9)  / 10000, // .09% Generation fee
            borrower: _borrower
        });

        // ensure the venft can handle the loan:
        // get expected return on the locked aero within the venft
        // uint veEscrowBalance = ve.balanceOfNFT(_tokenId);

        // IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        // routes[0] = IAerodromeRouter.Route(address(aeroToken),usdc,false, aeroFactory);
        // uint256[] memory lockedValue = aeroRouter.getAmountsOut(veEscrowBalance,routes);


        // require(
        //     _loanAmount * 10 <= lockedValue[0],
        //     "AerodromeVenft: insufficient balance"
        // );


        _loans[_tokenId] = loan;

        address[] memory pools = new address[](1);
        pools[0] = pool;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100000000000000000000;

        voter.vote(_tokenId, pools, amounts);
    }


    function advance(uint256 tokenId) external {
        address[] memory voters = new address[](1);
        voters[0] = address(voter);

        // get beginning balance of token before claiming fees
        uint256 balance0Before = IERC20(usdc).balanceOf(address(this));
        // uint256 balance1Before = IERC20(usdc).balanceOf(address(this));

        address[][] memory tokens = new address[][](1);
        address[] memory poolTokens = new address[](1);
        poolTokens[0] = usdc;
        tokens[0] = poolTokens;

        voter.claimFees(voters, tokens, tokenId);

        // get ending balance of token after claiming fees
        uint256 balance0After = IERC20(usdc).balanceOf(address(this));
        // uint256 balance1After = IERC20(usdc).balanceOf(address(this));

        // calculate the amount of fees claimed
        uint256 claimedFees = balance0After - balance0Before;

        _repay(tokenId, claimedFees);
    }

    
    function _repay(uint256 _tokenId, uint256 _amount) internal {
        LoanLibrary.LoanInfo storage loan = _loans[_tokenId];
        uint256 protocolFee = 0;
        uint256 providerFee = 0;
        IERC20(usdc).transfer(protocol, protocolFee);
        IERC20(usdc).transfer(provider, providerFee);
        // CLAIM TO GO INTO NFT
        // if (_principalPayoff > 0) {
        //     IERC20(usdc).transfer(parent, _amount - protocolFee - providerFee);
        // }
        // if (_excess > 0) {
        //     IERC20(usdc).transfer(loan.borrower, _principalPayoff);
        // }
        // loan.balance -= _principalPayoff;
        // loan.fees -= _feePayoff;
    }


    // function claimToken() {
    //         // confirm dont lose reqrds
    //         // autoocompound?
    // }

    // swap paired token to usdc using aeroRouter
    function swapToUsdc(uint256 amountIn) public returns(uint256 amountOut){
        pairedToken.approve(address(aeroRouter),pairedToken.balanceOf(address(this)));
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route(address(pairedToken),usdc,false, aeroFactory);
        uint256[] memory returnAmounts = aeroRouter.getAmountsOut(amountIn,routes);
        uint256[] memory amounts = aeroRouter.swapExactTokensForTokens(//swap usdc back to eth
            amountIn,
            returnAmounts[1],
            routes,
            address(this),
            block.timestamp
        ); 
        return amounts[0];
    }

    function getLoanDetails(uint256 _tokenId) external view returns (LoanLibrary.LoanInfo memory) {
        return _loans[_tokenId];
    }
    
    function payLoan(
        address _module,
        uint256 _tokenId,
        uint256 _amount
    ) external {
        _repay(_tokenId, _amount);
    }
}
