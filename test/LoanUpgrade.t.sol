// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolTimeLibrary} from "src/libraries/ProtocolTimeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import { console} from "forge-std/console.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(
        address minter,
        uint256 minterAllowedAmount
    ) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

contract LoanUpgradeTest is Test {
    uint256 fork;

    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow =
        IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan =
        Loan(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
    address owner;
    address user;
    uint256 tokenId = 68510;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        owner = address(loan.owner());
        user = votingEscrow.ownerOf(tokenId);
        if (address(loan) == address(user)) {
            vm.prank(address(loan));
            votingEscrow.transferFrom(address(loan), address(1), tokenId);
            user = votingEscrow.ownerOf(tokenId);
            vm.roll(block.number + 1);
        }

        vm.startPrank(owner);
        Loan loanV2 = new Loan();
        vault = Vault(loan._vault());
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        loan.setRewardsRate(11300);

        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        vm.stopPrank();

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        vm.stopPrank();
        
    }

    function testPoke() public {
        vm.startPrank(user);
        voter.poke(tokenId);
        vm.stopPrank();
    }

    function testMaxLoanVaultUnderfunded() public {
        vm.startPrank(loan._vault());
        usdc.approve(address(this), usdc.balanceOf(loan._vault()));
        usdc.transfer(address(this), usdc.balanceOf(loan._vault()));
        vm.stopPrank();

        vm.prank(owner);
        tokenId = 10131;
        loan.setMultiplier(80000000000000000);
        vm.stopPrank();
        (uint256 maxLoan,) = loan.getMaxLoan(tokenId);

        
        assertEq(maxLoan, 0, "max loan should be 0");
        assertEq(loan._outstandingCapital(), loan._outstandingCapital());
    }


    function testMaxLoanVault90Percent() public {
        vm.startPrank(loan._vault());
        usdc.approve(address(this), usdc.balanceOf(loan._vault()));
        usdc.transfer(address(this), usdc.balanceOf(loan._vault()));
        vm.stopPrank();

        usdc.mint(address(loan._vault()), loan._outstandingCapital() / 10 );


        vm.prank(owner);
        tokenId = 10131;
        loan.setMultiplier(80000000000000000);
        vm.stopPrank();
        (uint256 maxLoan,) = loan.getMaxLoan(tokenId);

        assertEq(maxLoan, 0, "max loan should be 0");
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testGetMaxLoan() public view {
        (uint256 maxLoan, ) = loan.getMaxLoan(tokenId);
        console.log("max loan", maxLoan / 1e6);
        assertTrue(maxLoan / 1e6 > 10);
    }

    function testNftOwner() public view {
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    function testLoanFailBelowOneCent() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = .001e6;
        vm.expectRevert("Amount must be greater than .01 USDC");
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
    }

    function testLoanRequest() public {
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        uint256 startingVaultBalance = usdc.balanceOf(address(vault));
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 5e18;
        vm.expectRevert("Cannot increase loan beyond max loan amount");
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);


        amount = 1e6;
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) >= 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < startingVaultBalance);

        (uint256 balance, address borrower,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "loan balance should be greater than 0");
        assertEq(borrower, user, "borrower should be the user");

        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }

    function testConfirmUpgradable() public {
        vm.startPrank(owner);
        Loan loanV3 = new Loan();
        loan.upgradeToAndCall(address(loanV3), new bytes(0));
        Loan loanV4 = new Loan();
        loan.upgradeToAndCall(address(loanV4), new bytes(0));
        vm.stopPrank();
    }

    function testCurrentOwnerCanIncreaaseLoan() public {
        usdc.mint(address(vault), 10000e6);
        uint256 _tokenId = 64196;
        uint256 amount = 1e6;
        (, address _user,) = loan.getLoanDetails(_tokenId);
        vm.startPrank(_user);
        loan.increaseLoan(_tokenId, amount);
        vm.stopPrank();
    }

    function testcurrentOwnerCanPayLoan() public  {
        uint256 _tokenId = 64196;
        (uint256 balance, address _user,) = loan.getLoanDetails(_tokenId);

        usdc.mint(address(_user), 100e6);
        vm.startPrank(_user);
        usdc.approve(address(loan), balance);
        loan.pay(_tokenId, 0);
        loan.claimCollateral(_tokenId);
        vm.stopPrank();
        assertEq(votingEscrow.ownerOf(_tokenId), _user);
    }

    function testRequestLoan() public {
        uint256 _tokenId = 68510;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(_user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();

        uint256 loanWeight = loan.getTotalWeight();
        assertTrue(loanWeight > 0, "loan weight should be greater than 0");
    }


    function testVoting() public {
        uint256 _tokenId = 68510;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(_user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        vm.roll(block.number + 1);
        vm.warp(ProtocolTimeLibrary.epochStart(block.timestamp) + 7 days);
        loan.requestLoan(_tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.roll(block.number + 1);
        vm.warp(ProtocolTimeLibrary.epochStart(block.timestamp) + 7 days + 1);
        vm.expectRevert();
        loan.vote(_tokenId); // fails because not last day of epoch
        // last day of epoch
        vm.warp(ProtocolTimeLibrary.epochStart(block.timestamp) + 13 days);
        loan.vote(_tokenId);
        loan.vote(_tokenId);
        vm.stopPrank();

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        address[] memory pools = new address[](1);
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100e18;
        loan.setDefaultPools(pools, weights);
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        loan.vote(_tokenId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);
        loan.vote(_tokenId);

        uint256 loanWeight = loan.getTotalWeight();
        assertTrue(loanWeight > 0, "loan weight should be greater than 0");
    }


    function testRates() public {
        vm.startPrank(0x0000000000000000000000000000000000000000);
        vm.expectRevert();
        loan.setZeroBalanceFee(1e6);
        vm.stopPrank();


        vm.assertEq(loan.getZeroBalanceFee(), 100);
        vm.assertEq(loan.getRewardsRate(), 11300);
        vm.assertEq(loan.getLenderPremium(), 2000);
        vm.assertEq(loan.getProtocolFee(), 500);

        vm.startPrank(owner);
        loan.setZeroBalanceFee(1e6);
        loan.setRewardsRate(1e6);
        loan.setLenderPremium(1e6);
        loan.setProtocolFee(1e6);
        vm.stopPrank();

        vm.assertEq(loan.getZeroBalanceFee(), 1e6);
        vm.assertEq(loan.getRewardsRate(), 1e6);
        vm.assertEq(loan.getLenderPremium(), 1e6);
        vm.assertEq(loan.getProtocolFee(), 1e6);
    }

    function transferToMultiSig() public {
        vm.startPrank(owner);
        loan.transferOwnership(0x0000000000000000000000000000000000000000);
        vm.stopPrank();

        assertEq(loan.owner(), owner);
        vm.startPrank(0x0000000000000000000000000000000000000000);
        loan.acceptOwnership();
        vm.stopPrank();

        assertEq(loan.owner(), 0x0000000000000000000000000000000000000000);
    }   

    function testDefaultPools() public { 
        address _pool = loan._defaultPools(0);
        assertTrue(_pool != address(0), "default pool should not be 0");

        assertTrue(loan._defaultWeights(0) > 0, "default pool weight should be greater than 0");
        
        uint256 defaultPoolChangeTime = loan._defaultPoolChangeTime();
        assertTrue(defaultPoolChangeTime > 0, "default pool change time should be greater than 0");

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        address[] memory pools = new address[](2);
        pools[0] = address(0x52f38A65DAb3Cf23478cc567110BEC90162aB832);
        pools[1] = address(0x52f38A65DAb3Cf23478cc567110BEC90162aB832);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 50e18;
        weights[1] = 50e18;
        loan.setDefaultPools(pools, weights);
        vm.stopPrank();

        assertTrue(loan._defaultPools(0) == pools[0], "default pool should be updated");
        assertTrue(loan._defaultPools(1) == pools[1], "default pool should be updated");
        assertTrue(loan._defaultWeights(0) == weights[0], "default pool weight should be updated");
        assertTrue(loan._defaultWeights(1) == weights[1], "default pool weight should be updated");
        assertTrue(loan._defaultPoolChangeTime() >= defaultPoolChangeTime, "default pool change time should be updated");
    }
}

