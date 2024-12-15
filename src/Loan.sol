// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;
import {console} from "forge-std/console.sol";
import "./interfaces/IVoter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import  "./libraries/LoanLibrary.sol";
import { ILoanModule } from "./interfaces/ILoanModule.sol";

contract Loan is Ownable {
    using LoanLibrary for LoanLibrary.LoanInfo;
    IERC20 public usdc;
    
    mapping(address => mapping(uint256 => address)) public tokenModules;
    mapping(address => uint256) public latestModuleVersion;

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    function RegisterModule(address tokenAddress, address moduleAddress, uint256 version) public onlyOwner {
        // ensure module exists
        require(moduleAddress != address(0), "Module address cannot be 0x0");
        // ensure module is not already registered
        require(
            tokenModules[moduleAddress][version] == address(0),
            "Module already registered"
        );

        tokenModules[tokenAddress][version] = moduleAddress;
        latestModuleVersion[tokenAddress] = version;
    }

    function RequestLoan(
        address tokenAddress,
        uint256 tokenId,
        uint256 amount,
        bytes32 signedMessage
    ) public {
        // require the msg.sender to be the owner of the token
        require(
            IERC721(tokenAddress).ownerOf(tokenId) == msg.sender,
            "Only the owner of the token can request a loan"
        );

        require(_getLoanModule(tokenAddress, latestModuleVersion[tokenAddress]) != address(0), "Module not registered");

        address module = _getLoanModule(tokenAddress, latestModuleVersion[tokenAddress]);
        
        IERC721(tokenAddress).transferFrom(msg.sender, module, tokenId);
        IERC20(usdc).transfer(msg.sender, amount);
        
        ILoanModule(module).create(tokenAddress, tokenId, amount, msg.sender);
    }

    function getLoanDetails(address tokenAddress, uint256 tokenId, uint256 version) public view returns (uint256 balance, address borrower) {
        LoanLibrary.LoanInfo memory loan = ILoanModule(_getLoanModule(tokenAddress, version)).getLoanDetails(tokenId);
        return (loan.balance, loan.borrower);
    }

    function advance(address tokenAddress, uint256 tokenId, uint256 version) public {
        ILoanModule(_getLoanModule(tokenAddress, version)).advance(tokenId);
    }


    function _getLoanModule(address tokenAddress, uint256 version) internal view returns (address) {
        require(tokenModules[tokenAddress][version] != address(0), "Module not registered");
        return tokenModules[tokenAddress][version];
    }
}
