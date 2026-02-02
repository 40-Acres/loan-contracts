// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// import {Test, console} from "forge-std/Test.sol";
// import {Loan} from "../src/Loan.sol";
// import { IVoter } from "src/interfaces/IVoter.sol";
// import { Vault } from "src/Vault.sol";
// import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
// import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
// import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
// import { RateCalculator } from "src/RateCalculator.sol";

// interface IUSDC {
//     function balanceOf(address account) external view returns (uint256);
//     function mint(address to, uint256 amount) external;
//     function configureMinter(address minter, uint256 minterAllowedAmount) external;
//     function masterMinter() external view returns (address);
//     function approve(address spender, uint256 amount) external returns (bool);
//     function transfer(address recipient, uint256 amount) external returns (bool);

// }

// contract VaultTest is Test {
//     IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
//     IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
//     IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
//     IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
//     address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];

//     // deployed contracts
//     uint256 fork;
//     Vault vault;
//     Loan public loan;
//     RateCalculator rateCalculator;
//     address owner;
//     address user;
//     uint256 tokenId = 64196;

//     function setUp() public {
//         fork = vm.createFork(vm.envString("BASE_RPC_URL"));
//         vm.selectFork(fork);
//         vm.rollFork(24353746);

//         owner = vm.addr(0x123);
//         user = votingEscrow.ownerOf(tokenId);

//         loan = new Loan();
//         vault = new Vault(address(usdc), address(loan));
//         rateCalculator = new RateCalculator(address(loan));
//         loan.setVault(address(vault));
//         loan.transferOwnership(owner);
//         // allow this test contract to mint USDC
//         vm.prank(usdc.masterMinter());
//         usdc.configureMinter(address(this), type(uint256).max);
//         usdc.mint(address(this), 2000e6);
//         vm.stopPrank();
//     }

//     // FOR ON FRIDAY DONT APPROVE
//     function testOwner() public view {
//         address o = loan.owner();
//         assertEq(o, owner);
//     }

//     function testDepositWithdrawal() public {
//         uint256 amount = 100e6;
//         usdc.approve(address(vault), amount);
//         console.log(usdc.balanceOf(address(this)));
//         vault.deposit(amount, address(this));
//         assertEq(vault.totalAssets(), amount);
//         vault.withdraw(amount, address(this), address(this));
//         assertEq(vault.totalAssets(), 0);
//     }

//     function testDepositWithdrawalPlus() public {
//         uint256 amount = 100e6;
//         usdc.approve(address(vault), amount);
//         console.log(usdc.transfer(address(this), amount));
//         vault.deposit(amount, address(this));
//         vm.prank(usdc.masterMinter());
//         usdc.configureMinter(address(this), type(uint256).max);
//         usdc.mint(address(vault), 50e6);
//         vm.stopPrank();

//         assertEq(ERC4626(vault).maxWithdraw(address(this)), 149999999);
//         assertEq(vault.totalAssets(), 150e6);
//         vault.withdraw(ERC4626(vault).maxWithdraw(address(this)), address(this), address(this));
//         assertEq(vault.totalAssets(), 1);
//     }


//     function testDepositWithdrawalLoan() public {
//         uint256 amount = 100e6;
//         usdc.approve(address(vault), amount);
//         console.log(usdc.transfer(address(this), amount));
//         vault.deposit(amount, address(this));
//         vm.prank(usdc.masterMinter());
//         usdc.configureMinter(address(this), type(uint256).max);
//         usdc.mint(address(vault), 50e6);
//         vm.stopPrank();

//         assertEq(ERC4626(vault).maxWithdraw(address(this)), 149999999);
//         assertEq(vault.totalAssets(), 150e6);

//         vm.startPrank(user);
//         IERC721(address(votingEscrow)).approve(address(loan), tokenId);
//         loan.requestLoan(tokenId, .01e6, pool, Loan.ZeroBalanceOption.DoNothing);
//         vm.stopPrank();


//         vault.withdraw(ERC4626(vault).maxWithdraw(address(this))-.01e6, address(this), address(this));
//         assertEq(vault.totalAssets(), .01e6+1);
//     }
    
//     function testDepositWithdrawalLoanWithLoandsOut() public {
//         uint256 amount = 100e6;
//         usdc.approve(address(vault), amount);
//         console.log(usdc.transfer(address(this), amount));
//         vault.deposit(amount, address(this));
//         vm.prank(usdc.masterMinter());
//         usdc.configureMinter(address(this), type(uint256).max);
//         usdc.mint(address(vault), 50e6);
//         vm.stopPrank();

//         assertEq(ERC4626(vault).maxWithdraw(address(this)), 149999999);
//         assertEq(vault.totalAssets(), 150e6);

//         vm.startPrank(user);
//         IERC721(address(votingEscrow)).approve(address(loan), tokenId);
//         loan.requestLoan(tokenId, .01e6, pool, Loan.ZeroBalanceOption.DoNothing);
//         assertEq(ERC4626(vault).maxWithdraw(address(this)), 149999999);
//         vm.stopPrank();


//         vault.withdraw(ERC4626(vault).maxWithdraw(address(this))-.01e6, address(this), address(this));
//         assertEq(vault.totalAssets(), .01e6+1);
//     }
// }


