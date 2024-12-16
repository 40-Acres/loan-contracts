// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;
import {console} from "forge-std/console.sol";
import "./interfaces/IVoter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ILoanModule } from "./interfaces/ILoanModule.sol";

contract Loan is Ownable {
    IERC20 public usdc;
    uint256 _interestRate = 8;
    address _vault;
    bool public paused;
    uint256 activelyBorrowedAssets;

    mapping(address => mapping(uint256 => address)) public tokenModules;
    mapping(address => uint256) public latestModuleVersion;
    mapping(address => mapping(uint256 => LoanInfo)) public _loanDetails;


    struct LoanInfo {
        address tokenAddress;
        uint256 tokenId;
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
    }

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }


    function requestLoan(
        address tokenAddress,
        uint256 tokenId,
        uint256 amount
    ) public whenNotPaused {
        // require the msg.sender to be the owner of the token
        require(
            IERC721(tokenAddress).ownerOf(tokenId) == msg.sender,
            "Only the owner of the token can request a loan"
        );

        address module = _getLoanModule(tokenAddress, latestModuleVersion[tokenAddress]);
        
        uint256 originationFee = amount * 8 / 10000; // 0.8%


        IERC20(usdc).transferFrom(_vault, msg.sender, amount);
        IERC721(tokenAddress).transferFrom(msg.sender, module, tokenId);
        ILoanModule(module).initializeLoan(amount);

        _loanDetails[tokenAddress][tokenId] = LoanInfo({
            balance: amount + originationFee,
            borrower: msg.sender,
            timestamp: block.timestamp,
            tokenAddress: tokenAddress,
            outstandingCapital: amount,
            tokenId: tokenId
        });

        activelyBorrowedAssets += amount;
    }

    function increaseLoan(address tokenAddress, uint256 tokenId, uint256 amount) public whenNotPaused {
        LoanInfo storage loan = _loanDetails[tokenAddress][tokenId];
        require(loan.borrower == msg.sender, "Only the borrower can increase the loan");
        uint256 maxLoan = getMaxLoan(tokenAddress, tokenId);
        require(loan.balance + amount <= maxLoan, "Cannot increase loan beyond max loan amount");
        uint256 originationFee = amount * 8 / 10000; // 0.8%
        loan.balance += amount + originationFee;
        loan.outstandingCapital += amount;
        activelyBorrowedAssets += amount;
        IERC20(usdc).transferFrom(_vault, msg.sender, amount);
    }


    function advance(address tokenAddress, uint256 tokenId, uint256 version) public {
        address module = _getLoanModule(tokenAddress, version);
        uint256 amount = ILoanModule(module).repay(tokenId);

        LoanInfo storage loan = _loanDetails[tokenAddress][tokenId];
        loan.balance = _getCurrentLoanBalance(tokenAddress, tokenId);

        uint256 protocolFee = amount * 25 / 100;
        amount -= protocolFee;
        if(amount > loan.balance) {
            IERC20(usdc).transfer(loan.borrower, amount - loan.balance);
            amount = loan.balance;
            protocolFee = amount * 25 / 100;
        }
        loan.balance -= amount;

        if(amount > loan.outstandingCapital) {
            activelyBorrowedAssets -= loan.outstandingCapital;
            loan.outstandingCapital = 0;
        } else {
            loan.outstandingCapital -= amount;
            activelyBorrowedAssets -= amount;
        }
        IERC20(usdc).transfer(owner(), protocolFee);
        IERC20(usdc).transfer(_vault, amount);
    }

    function _getLoanModule(address tokenAddress, uint256 version) internal view returns (address) {
        require(tokenModules[tokenAddress][version] != address(0), "Module not registered");
        return tokenModules[tokenAddress][version];
    }

    function _getCurrentLoanBalance(address tokenAddress, uint256 tokenId) internal  returns (uint256) {
        uint256 timeSinceLastCalculation = block.timestamp - _loanDetails[tokenAddress][tokenId].timestamp;
        uint256 interest = _loanDetails[tokenAddress][tokenId].balance * _interestRate * timeSinceLastCalculation / 100;
        return _loanDetails[tokenAddress][tokenId].balance + interest;
    }

    function getMaxLoan(address tokenAddress, uint256 tokenId) public view returns (uint256) {
        ILoanModule module = ILoanModule(_getLoanModule(tokenAddress, latestModuleVersion[tokenAddress]));
        return module.getMaxLoan(tokenId);
    }

    /* RESCUE FUNCTIONS */
    function rescueERC20(address token, uint256 amount) public onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    function rescueERC721(address token, uint256 tokenId) public onlyOwner {
        IERC721(token).transferFrom(address(this), owner(), tokenId);
    }

    /* VIEW FUNCTIONS */
    function getLoanDetails(address tokenAddress, uint256 tokenId) public returns (uint256 balance, address borrower) {
        LoanInfo storage loan = _loanDetails[tokenAddress][tokenId];
        loan.balance = _getCurrentLoanBalance(tokenAddress, tokenId);
        return (loan.balance, loan.borrower);
    }

    function activeAssets() public view returns (uint256) {
        return activelyBorrowedAssets;
    }

    /* MODIFIERS */
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    /* OWNER FUNCTIONS */
    function setVault(address vault) public onlyOwner {
        if(_vault != address(0)) {
           revert("Vault can only be set once");
        }
        _vault = vault;
    }

    function registerModule(address tokenAddress, address moduleAddress, uint256 version) public onlyOwner {
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

    function pause() public onlyOwner {
        paused = true;
    }

    function unpause() public onlyOwner {
        paused = false;
    }


}
