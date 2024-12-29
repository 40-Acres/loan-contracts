pragma solidity ^0.8.28;

import {IVoter} from "../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "../../interfaces/IAerodromeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631
// VOTER = 0x16613524e02ad97edfef371bc883f2f5d6c480a5 
// VOTING ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4
// AERODROME/USDC = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d
// REWARDS DISTRIBUTOR = 0x227f65131a261548b057215bb1d5ab2997964c7d

contract AerodromeVenft {
    IVoter public _voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address public _vault;
    address public _votingRewards = 0x765d935C2F47a06EdA55D07a9b9aE4108F4BBF85; // USDC/WETH
    address public _bribeRewards = 0x685b5173e002B2eC55A8cd02C74d5ee77043Eb1e; // USDC/WETH
    address public _rewardsDistributor = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // USDC/WETH
    address private _pool; // pool to vote on to receive fees
    address private _asset; // USDC
    IERC20 private _pairedToken = IERC20(0x4200000000000000000000000000000000000006); // Paired token to USDC in the voted pool
    address private _parent; // parent contract
    IVotingEscrow private _ve = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IAerodromeRouter private _aeroRouter = IAerodromeRouter(0x9c7305eb78a432ced5C4D14Cac27E8Ed569A2e26);
    address private _aeroFactory = address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);


    constructor(
        address token0,
        address pool,
        address parent,
        address vault
    ) {
        _asset = token0;
        _pool = pool;
        _parent = parent;
        _vault = vault;
    }

    modifier onlyParent() {
        require(msg.sender == _parent, "AerodromeVenft: Only parent contract can call this function");
        _;
    }

    function initializeLoan(uint256 tokenId) external returns (uint256 maxLoan) {
        address[] memory pools = new address[](1);
        pools[0] = _pool;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        // ensure the token is locked permanently
        if (!_ve.locked(tokenId).isPermanent) {
            _ve.lockPermanent(tokenId);
        }

        _voter.vote(tokenId, pools, amounts);

        return 0;
    }

    function getRewards(uint256 tokenId) public returns (uint256 payment) {
        address[] memory voters = new address[](1);
        voters[0] = address(_voter);

        // get beginning balance of token before claiming fees
        uint256 prebalanceAsset = IERC20(_asset).balanceOf(address(this));
        // uint256 prebalanceToken = IERC20(_pairedToken).balanceOf(address(this));

        address[][] memory tokens = new address[][](1);
        address[] memory poolTokens = new address[](1);
        poolTokens[0] = _asset;
        tokens[0] = poolTokens;

        address[] memory rewardsContract = new address[](1);
        address[] memory bribeContract = new address[](1);
        rewardsContract[0] = _votingRewards;
        bribeContract[0] = _bribeRewards;
        _voter.claimFees(rewardsContract, tokens, tokenId);
        // swap paired token to usdc
        uint256 postBalanceToken = IERC20(_asset).balanceOf(address(this));
        // swapToUsdc(postBalanceToken - prebalanceToken);

        // get ending balance of token after claiming fees
        uint256 postBalanceAsset = IERC20(_asset).balanceOf(address(this));

        // calculate the amount of fees claimed
        payment = postBalanceAsset - prebalanceAsset;

        IERC20(_asset).transfer(_parent, payment);
    }



    // swap paired token to usdc using aeroRouter
    function swapToUsdc(uint256 amountIn) internal returns(uint256 amountOut)  {
        _pairedToken.approve(address(_aeroRouter),_pairedToken.balanceOf(address(this)));
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route(address(_pairedToken),_asset,false, _aeroFactory);
        uint256[] memory returnAmounts = _aeroRouter.getAmountsOut(amountIn,routes);
        uint256[] memory amounts = _aeroRouter.swapExactTokensForTokens(//swap usdc back to eth
            amountIn,
            returnAmounts[1],
            routes,
            address(this),
            block.timestamp
        ); 
        return amounts[0];
    }


    function getMaxLoan(uint256 tokenId) external view returns (uint256) {
        // Max loan is max of USDC balance of vault or 100 USDC or .0113 * veNFT balance of token * 8
        uint256 maxLoan = 1000e18;
        uint256 vaultBalance = IERC20(_asset).balanceOf(_vault);
        if (vaultBalance > maxLoan) {
            maxLoan = vaultBalance;
        }

        uint256 veBalance = _ve.balanceOfNFTAt(tokenId, block.timestamp);
        uint256 veBalanceUSD = veBalance * 113 / 10000 * 8; // 0.0113 * veNFT balance of token
        if (veBalanceUSD > maxLoan) {
            maxLoan = veBalanceUSD;
        }
        return maxLoan;
    }

    function claimCollateral(uint256 tokenId, address to) external onlyParent {
        // _to is checked in the parent contract
        _ve.transferFrom(address(this), to, tokenId);
    }
}
