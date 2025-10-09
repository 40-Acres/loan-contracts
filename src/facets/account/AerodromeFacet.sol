// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../storage/CollateralStorage.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";

/**
 * @title AerodromeFacet
 * @dev Middleware facet that interfaces with the loan contract
 */
contract AerodromeFacet {
    PortfolioFactory public immutable _portfolioFactory;
    IERC20 public immutable _aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IERC721 public immutable _ve = IERC721(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    address public immutable _entryPoint = 0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA;


    constructor(address portfolioFactory) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
    }

    function aerodromeClaimCollateral(address loanContract, uint256 tokenId) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        ILoan(loanContract).claimCollateral(tokenId);
        address asset = address(ILoan(loanContract)._ve());
        (uint256 balance, address borrower) = ILoan(loanContract).getLoanDetails(tokenId);
        // ensure the token doesnt have a loan within the loan contract
        require(borrower == address(0) && balance == 0);
        IVotingEscrow(asset).transferFrom(address(this), msg.sender, tokenId);
        CollateralStorage.removeNonfungibleCollateral(asset, tokenId);
    }

    function aerodromeIncreaseLoan(address loanContract, uint256 tokenId, uint256 amount) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        ILoan(loanContract).increaseLoan(tokenId, amount);
        address asset = address(ILoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function aerodromeRequestLoan(address loanContract, uint256 tokenId, uint256 amount, ILoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp, bool optInCommunityRewards) external {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        if(IERC721(_ve).ownerOf(tokenId) != address(this)) {
            IERC721(_ve).transferFrom(msg.sender, address(this), tokenId);
        }
        ILoan(loanContract).requestLoan(tokenId, amount, zeroBalanceOption, increasePercentage, preferredToken, topUp, optInCommunityRewards);
        address asset = address(ILoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);

        CollateralStorage.addNonfungibleCollateral(address(_ve), tokenId);

    }

    function aerodromeVote(address loanContract, uint256 tokenId) external returns (bool success) {
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IERC721(_ve).setApprovalForAll(address(loanContract), true);
        success = ILoan(loanContract).vote(tokenId);
        IERC721(_ve).setApprovalForAll(address(loanContract), false);
    }

    function aerodromeUserVote(address loanContract, uint256[] calldata tokenIds, address[] calldata pools, uint256[] calldata weights) external {
        IERC721(_ve).setApprovalForAll(address(loanContract), true);
        ILoan(loanContract).userVote(tokenIds, pools, weights);
        IERC721(_ve).setApprovalForAll(address(loanContract), false);
    }

    function aerodromeClaim(address loanContract, uint256 tokenId, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external returns (uint256) {
        require(msg.sender == _entryPoint);
        IERC721(_ve).setApprovalForAll(address(loanContract), true);
        uint256 result = ILoan(loanContract).claim(tokenId, fees, tokens, tradeData, allocations);
        IERC721(_ve).setApprovalForAll(address(loanContract), false);
        if(allocations[1] > 0) {
            uint256 aeroAmount = _aero.balanceOf(address(this));
            if(allocations[1] < aeroAmount) {
                aeroAmount = allocations[1];
            }
            IERC20(_aero).approve(address(_ve), aeroAmount);
            IVotingEscrow(address(_ve)).increaseAmount(tokenId, aeroAmount);
        }
        return result;
    }

    function withdrawNFT(uint256 tokenId) external {
        require(CollateralStorage.getNonfungibleCollateral(address(_ve), tokenId) == false);
        require(msg.sender == _portfolioFactory.getAccountOwner(address(this)));
        IERC721(_ve).transferFrom(address(this), msg.sender, tokenId);
    }
}



