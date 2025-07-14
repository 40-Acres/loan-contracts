// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {DeploySwapper} from "../script/BaseDeploySwapper.s.sol";
import {Swapper} from "../src/Swapper.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";
import {IFlashLoanProvider} from "../src/interfaces/IFlashLoanProvider.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

/**
 * @title MockFlashLoanReceiver
 * @notice Mock contract for testing flash loans
 */
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    address public immutable loanContract;
    IERC20 public immutable token;
    bool public shouldRepay;
    bool public shouldApprove;
    uint256 public profit;

    event FlashLoanReceived(address token, uint256 amount, uint256 fee);

    constructor(address _loanContract, address _token) {
        loanContract = _loanContract;
        token = IERC20(_token);
        shouldRepay = true;
        shouldApprove = true;
    }

    function executeFlashLoan(uint256 amount) external {
        // Call flash loan
        IFlashLoanProvider(loanContract).flashLoan(
            this,
            address(token),
            amount,
            ""
        );
    }

    function onFlashLoan(
        address initiator,
        address tokenAddress,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == loanContract, "Caller is not the flash loan provider");
        require(tokenAddress == address(token), "Invalid token");

        emit FlashLoanReceived(tokenAddress, amount, fee);

        // Mock some arbitrage or business logic here
        // For testing, we just check the balance
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "Did not receive loan");

        // If configured to repay, we approve and let the loan contract pull the funds
        if (shouldRepay && shouldApprove) {
            token.approve(loanContract, amount + fee);
        }

        return CALLBACK_SUCCESS;
    }

    // Test utility functions
    function setShouldRepay(bool _shouldRepay) external {
        shouldRepay = _shouldRepay;
    }

    function setShouldApprove(bool _shouldApprove) external {
        shouldApprove = _shouldApprove;
    }

    // Function to simulate profit
    function mockProfit(uint256 amount) external {
        profit = amount;
    }

    // Allow withdrawal of tokens
    function withdraw(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract FlashLoanTest is Test {
    uint256 fork;

    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);

    // Deployed contracts
    Vault vault;
    Loan public loan;
    address owner;
    address user;
    MockFlashLoanReceiver flashLoanReceiver;

    // Test amounts
    uint256 constant FLASH_LOAN_AMOUNT = 1e6; // 1 USDC
    uint256 constant VAULT_INITIAL_BALANCE = 100e6; // 100 USDC

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24353746);
        
        owner = vm.addr(0x123);
        user = vm.addr(0x456);
        
        // Deploy contracts
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        DeploySwapper swapperDeploy = new DeploySwapper();
        Swapper swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));
        vm.stopPrank();

        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Configure USDC minting
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        
        // Fund the vault with USDC for flash loans
        usdc.mint(address(vault), VAULT_INITIAL_BALANCE);
        
        // Create flash loan receiver
        flashLoanReceiver = new MockFlashLoanReceiver(address(loan), address(usdc));
        
        // Make sure vault approves the loan contract to transfer tokens
        vm.prank(address(vault));
        usdc.approve(address(loan), type(uint256).max);
        
        vm.stopPrank();
    }

    function testMaxFlashLoan() public {
        uint256 maxLoan = loan.maxFlashLoan(address(usdc));
        assertEq(maxLoan, VAULT_INITIAL_BALANCE, "Max flash loan should equal vault balance");
        
        // Test with invalid token
        uint256 maxLoanInvalid = loan.maxFlashLoan(address(0x1234));
        assertEq(maxLoanInvalid, 0, "Max flash loan for invalid token should be 0");
    }

    function testFlashFee() public {
        uint256 amount = 1000e6; // 1000 USDC
        uint256 fee = loan.flashFee(address(usdc), amount);
        uint256 expectedFee = (amount * 9) / 10000; // 0.09% fee
        assertEq(fee, expectedFee, "Flash loan fee calculation is incorrect");
        
        // Test with invalid token
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", address(0x1234)));
        loan.flashFee(address(0x1234), amount);
    }

    function testFlashLoanSuccess() public {
        uint256 initialVaultBalance = usdc.balanceOf(address(vault));
        uint256 amount = FLASH_LOAN_AMOUNT;

        uint256 fee = (amount * 9) / 10000; // 0.09% fee


        usdc.mint(address(flashLoanReceiver), fee);
        
        // Execute flash loan
        vm.prank(user);
        flashLoanReceiver.executeFlashLoan(amount);
        
        // Verify balances after flash loan
        uint256 finalVaultBalance = usdc.balanceOf(address(vault));
        
        assertEq(finalVaultBalance, initialVaultBalance + fee, "Vault should receive fee");
        
        // Check that rewards were recorded
        uint256 rewardsInEpoch = loan.lastEpochReward();
        assertEq(rewardsInEpoch, fee, "Fee should be recorded as rewards");
    }

    function testFlashLoanFailureNoApproval() public {
        uint256 amount = FLASH_LOAN_AMOUNT;
        
        // Configure receiver to not approve repayment
        flashLoanReceiver.setShouldApprove(false);
        
        // Execute flash loan, should fail
        vm.expectRevert("Insufficient allowance for repayment");
        vm.prank(user);
        flashLoanReceiver.executeFlashLoan(amount);
    }

    function testFlashLoanExceedsAvailable() public {
        uint256 amount = VAULT_INITIAL_BALANCE + 1; // More than available
        
        // Execute flash loan, should fail
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxLoan(uint256)", VAULT_INITIAL_BALANCE));
        vm.prank(user);
        flashLoanReceiver.executeFlashLoan(amount);
    }

    function testUnsupportedToken() public {
        address unsupportedToken = address(0x1234);
        
        // Try to flash loan an unsupported token
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", unsupportedToken));
        loan.flashLoan(flashLoanReceiver, unsupportedToken, 1000, "");
    }

    function testFlashLoanWithCallbackFailure() public {
        // Create an invalid receiver that returns the wrong value
        MockInvalidFlashLoanReceiver invalidReceiver = new MockInvalidFlashLoanReceiver(address(loan), address(usdc));
        
        // Fund the vault with USDC
        vm.prank(address(vault));
        usdc.approve(address(loan), type(uint256).max);
        
        // Execute flash loan, should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidFlashLoanReceiver(address)", address(invalidReceiver)));
        vm.prank(user);
        invalidReceiver.executeFlashLoan(FLASH_LOAN_AMOUNT);
    }
}

/**
 * @title MockInvalidFlashLoanReceiver
 * @notice Mock contract that intentionally returns the wrong callback value
 */
contract MockInvalidFlashLoanReceiver is IFlashLoanReceiver {
    bytes32 public constant INVALID_RETURN = keccak256("InvalidReturn");
    address public immutable loanContract;
    IERC20 public immutable token;

    constructor(address _loanContract, address _token) {
        loanContract = _loanContract;
        token = IERC20(_token);
    }

    function executeFlashLoan(uint256 amount) external {
        // Call flash loan
        IFlashLoanProvider(loanContract).flashLoan(
            this,
            address(token),
            amount,
            ""
        );
    }

    function onFlashLoan(
        address initiator,
        address tokenAddress,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == loanContract, "Caller is not the flash loan provider");
        
        // Approve the repayment
        token.approve(loanContract, amount + fee);
        
        // Return invalid value to make the callback fail
        return INVALID_RETURN;
    }
}