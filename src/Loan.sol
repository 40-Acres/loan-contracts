// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;

import "./interfaces/IVoter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import  "./libraries/LoanLibrary.sol";
import { IModule } from "./interfaces/IModule.sol";

contract Loan is Ownable {
    using LoanLibrary for LoanLibrary.LoanInfo;
    
    // mapping of token address to module address
    mapping(address => address) public tokenModules;


    mapping(address => mapping(uint256 => LoanLibrary.LoanInfo)) public tokenLoans;

    constructor() Ownable(msg.sender) {}

    function RegisterModule(address tokenAddress, address moduleAddress) public onlyOwner {
        // ensure module exists
        require(moduleAddress != address(0), "Module address cannot be 0x0");
        // ensure module is not already registered
        require(
            tokenModules[moduleAddress] == address(0),
            "Module already registered"
        );

        tokenModules[tokenAddress] = moduleAddress;
    }

    function RequestLoan(
        address tokenAddress,
        uint256 tokenId,
        uint256 amount,
        uint256 expiration,
        bytes32 signedMessage, 
        uint8 _v, 
        bytes32 _r, 
        bytes32 _s
    ) public {
        // require the msg.sender to be the owner of the token
        require(
            IERC721(tokenAddress).ownerOf(tokenId) == msg.sender,
            "Only the owner of the token can request a loan"
        );


        // require a signed message from the owner of the contract
        require(
            verifySignature(
                signedMessage,
                _v,
                _r,
                _s
            ) == owner(),
            "Invalid signature"
        );

        // ensure signed message is valid
        require(
            keccak256(abi.encodePacked(tokenAddress, tokenId, amount, expiration)) == signedMessage,
            "Invalid signed message"
        );

        // require current time to be less than expiration
        require(block.timestamp < expiration, "Loan request expired");

        require(tokenModules[tokenAddress] != address(0), "Module not registered");

        LoanLibrary.LoanInfo memory loan = IModule(tokenModules[tokenAddress]).createLoan(tokenAddress, tokenId, msg.sender, expiration);

        tokenLoans[tokenAddress][tokenId] = loan;
    }

    function getLoanDetails(address tokenAddress, uint256 tokenId) public view returns (uint256 amountPaid, uint256 startTime, uint256 endTime, address borrower, bool active) {
        LoanLibrary.LoanInfo memory loan = tokenLoans[tokenAddress][tokenId];
        return (loan.amountPaid, loan.startTime, loan.endTime, loan.borrower, loan.active);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    function verifySignature(bytes32 message, uint8 v, bytes32 r, bytes32 s) public pure returns (address) {
        return ECDSA.recover(message, v, r, s);
    }
}
