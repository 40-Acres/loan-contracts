// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/VeloLoan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ProtocolTimeLibrary } from "src/libraries/ProtocolTimeLibrary.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {OpDeploy} from "../script/OpDeploy.s.sol";
import {OpUpgrade} from "../script/OpUpgrade.s.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {DeploySwapper} from "../script/OpDeploySwapper.s.sol";
import { Swapper } from "../src/Swapper.sol";


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


contract VeloLoanTest is Test {
    uint256  fork;

    IUSDC usdc = IUSDC(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    IVotingEscrow votingEscrow = IVotingEscrow(0xFAf8FD17D9840595845582fCB047DF13f006787d);
    uint256[] weights = [100e18];
    ProxyAdmin admin;
    IVoter voter = IVoter(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);

    // deployed contracts
    Vault vault;
    Loan public loan;
    address owner;
    address user;
    uint256 tokenId = 2087;

    Swapper public swapper;

    function setUp() public {
        fork = vm.createFork(vm.envString("OP_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(131270259);
        owner = vm.addr(0x1234);
        user = votingEscrow.ownerOf(tokenId);
        OpDeploy deployer = new OpDeploy();
        (loan, vault) = deployer.deployLoan();

        vm.startPrank(address(deployer));
        loan.setMultiplier(10000000000000);

        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));

        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();
        address[] memory pools = new address[](1);
        pools[0] = address(0xa0A215dE234276CAc1b844fD58901351a50fec8A);
        loan.setDefaultPools(pools, weights);
        vm.stopPrank();
        
        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(vault), 100e6);

        vm.stopPrank();
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }


    function testGetMaxLoan() public view {
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertTrue(maxLoan / 1e6 > 10);
    }

    function testNftOwner() public view {
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    function testLoanRequest() public {
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 5e18;
        vm.expectRevert("Cannot increase loan beyond max loan amount");
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.roll(block.number+1);

        amount = 1e6;
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.roll(block.number+1);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        (uint256 balance, address borrower,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }


    function testLoanVotingAdvance() public {
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Vault should have 1e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);

        
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");


        address op = address(0x4200000000000000000000000000000000000042);
        address weth = address(0x4200000000000000000000000000000000000006);
        address velo = address(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);
        
        address[] memory bribes = new address[](4);
        bribes[0] = op;
        bribes[1] = weth;
        bribes[2] = velo;
        bribes[3] = address(usdc);
        _claimRewards(loan, tokenId, bribes);
        assertTrue(usdc.balanceOf(address(vault)) > 99e6, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 201600);

        assertEq(vault.epochRewardsLocked(), 18635);
    }

    function testIncreaseLoan() public {
        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6, "User should have more than loan");

        assertEq(loan.activeAssets(),1e6, "ff");
        (uint256 balance, address borrower,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be 1e6");
        assertEq(borrower, user);

        vm.startPrank(user);
        loan.increaseLoan(tokenId, amount);
        vm.stopPrank();

        (balance, borrower,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);
        assertEq(loan.activeAssets(),2e6, "ff");

        assertEq(usdc.balanceOf(address(user)), 2e6 + startingUserBalance, "User should have .02e6");
        assertEq(usdc.balanceOf(address(vault)), 98e6, "Loan should have 1e6");
        
    }



    function testLoanFullPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);
        vm.stopPrank();

        uint256 amount = 1e6;

        assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), 1e6+startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Loan should have 97e6");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        loan.pay(tokenId, 0);
        loan.claimCollateral(tokenId);
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(tokenId), address(user));
        assertEq(usdc.balanceOf(address(vault)), 100e6, "ault should have initial balance");
        assertTrue(usdc.balanceOf(address(owner)) > startingOwnerBalance, "User should have more than starting balance");
    }


    function testUpgradeLoan() public {
        vm.startPrank(loan.owner());
        Loan loanV2 = new Loan();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();
    }


    function testClaimFourPools() public {
        vm.rollFork(133415048);

        Loan loan = Loan(0xf132bD888897254521D13e2c401e109caABa06A7);
        vm.startPrank(IOwnable(address(loan)).owner());
        loan.upgradeToAndCall(address(new Loan()), new bytes(0));

        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));


        address op = address(0x4200000000000000000000000000000000000042);
        address weth = address(0x4200000000000000000000000000000000000006);
        address velo = address(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);


 
        assertEq(ERC20(velo).balanceOf(address(loan)), 0, "should have 0 velo balance");
        assertEq(ERC20(op).balanceOf(address(loan)), 0, "should have 0 op balance");
        assertEq(ERC20(weth).balanceOf(address(loan)), 0, "should have 0 weth balance");
        
        vm.roll(block.number+1);        
        address[] memory bribes = new address[](4);
        bribes[0] = op;
        bribes[1] = weth;
        bribes[2] = velo;
        bribes[3] = address(usdc);
        _claimRewards(loan, 11008, bribes);
        // asert loan has no token balance
        assertEq(ERC20(velo).balanceOf(address(loan)), 0);
        assertEq(ERC20(op).balanceOf(address(loan)), 0);
        assertEq(ERC20(weth).balanceOf(address(loan)), 0);
        assertEq(115427935842, usdc.balanceOf(address(0x08dCDBf7baDe91Ccd42CB2a4EA8e5D199d285957)));
    }

    function testClaimBribes() public {
        vm.rollFork(133415048);

        Loan loan = Loan(0xf132bD888897254521D13e2c401e109caABa06A7);
        vm.startPrank(IOwnable(address(loan)).owner());
        loan.upgradeToAndCall(address(new Loan()), new bytes(0));

        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));
        address op = address(0x4200000000000000000000000000000000000042);
        address weth = address(0x4200000000000000000000000000000000000006);
        address velo = address(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);
 
        assertEq(ERC20(velo).balanceOf(address(loan)), 0, "should have 0 velo balance");
        assertEq(ERC20(op).balanceOf(address(loan)), 0, "should have 0 op balance");
        assertEq(ERC20(weth).balanceOf(address(loan)), 0, "should have 0 weth balance");
        
        vm.roll(block.number+1);
        // asert loan has no token balance
        address[] memory bribes = new address[](4);
        bribes[0] = op;
        bribes[1] = weth;
        bribes[2] = velo;
        bribes[3] = address(usdc);
        _claimRewards(loan, 11008, bribes);
        assertEq(ERC20(velo).balanceOf(address(loan)), 0);
        assertEq(ERC20(op).balanceOf(address(loan)), 0);
        assertEq(ERC20(weth).balanceOf(address(loan)), 0);
        assertEq(115427935842, usdc.balanceOf(address(0x08dCDBf7baDe91Ccd42CB2a4EA8e5D199d285957)));
    }

    function _claimRewards(Loan _loan, uint256 _tokenId, address[] memory bribes) internal {
        address[] memory pools = new address[](256); // Assuming a maximum of 256 pool votes
        uint256 index = 0;

        while (true) {
            try voter.poolVote(_tokenId, index) returns (address pool) {
            pools[index] = pool;
            console.log("pools[%s]: %s", index, pool);
            index++;
            } catch {
            break; // Exit the loop when it reverts
            }
        }

        address[] memory voterPools = new address[](index);
        for (uint256 i = 0; i < index; i++) {
            voterPools[i] = pools[i];
        }
        address[] memory fees = new address[](2 * voterPools.length);
        address[][] memory tokens = new address[][](2 * voterPools.length);

        for (uint256 i = 0; i < voterPools.length; i++) {
            address gauge = voter.gauges(voterPools[i]);
            fees[2 * i] = voter.gaugeToFees(gauge);
            fees[2 * i + 1] = voter.gaugeToBribe(gauge);
            address[] memory token = new address[](2);
            token[0] = ICLGauge(voterPools[i]).token0();
            token[1] = ICLGauge(voterPools[i]).token1();
            tokens[2 * i] = token;
            address[] memory bribeTokens = new address[](bribes.length + 2);
            for (uint256 j = 0; j < bribes.length; j++) {
                bribeTokens[j] = bribes[j];
            }
            bribeTokens[bribes.length] = token[0];
            bribeTokens[bribes.length + 1] = token[1];
            tokens[2 * i + 1] = bribeTokens;
        }
        _loan.claim(_tokenId, fees, tokens);
    }
}
