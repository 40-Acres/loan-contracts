// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Loan } from "./LoanV2.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract LoanDemo {
    Loan public _loan;
    uint256 public _tokenId;
    address public _owner;
    IERC721 public _ve;
    IERC20 public _usdc;

    constructor(address loan, address ve, address usdc) {
        _usdc = IERC20(usdc);
        _loan = Loan(loan);
        _ve = IERC721(ve);
    }

    function deposit(
        uint256 tokenId
    ) public {
        require(_tokenId == 0, "Token already added");
        _ve.transferFrom(msg.sender, address(this), tokenId);
        _tokenId = tokenId;
        _owner = msg.sender;
    }
    
    function withdraw() public {
        require(_tokenId != 0, "No token to remove");
        require(msg.sender == _owner, "Only owner can remove token");
        _ve.transferFrom(address(this), msg.sender, _tokenId);
        _tokenId = 0;
        _owner = address(0);
    }

    function requestLoan(
        uint256 tokenId,
        uint256 amount,
        Loan.ZeroBalanceOption zeroBalanceOption
    ) external {
        require(tokenId == tokenId, "Token ID mismatch");
        _ve.approve(address(_loan), tokenId);
        _loan.requestLoan(
            tokenId,
            amount,
            zeroBalanceOption,
            0, 
            false
        );
    }

    function increaseLoan(
        uint256 tokenId,
        uint256 amount
    ) external {
        require(_tokenId == tokenId, "Token ID mismatch");
        _loan.increaseLoan(
            tokenId,
            amount
        );
    }

    function claimCollateral(
        uint256 tokenId
    ) external {
        require(_tokenId == tokenId, "Token ID mismatch");
       _loan.claimCollateral(
            tokenId
        );
    }

    function pay(
        uint256 tokenId,
        uint256 amount
    ) external {
        require(_tokenId == tokenId, "Token ID mismatch");
        _usdc.approve(address(_loan), _usdc.balanceOf(address(this)));
        _loan.pay(
            tokenId,
            amount
        );
    }

    function rescueErc20(
        address token,
        uint256 amount
    ) public {
        IERC20(token).transfer(_owner, amount);
    }
}