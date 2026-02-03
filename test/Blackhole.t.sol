// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
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
import {BlackholeDeploy} from "../script/BlackholeDeploy.s.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import { IMinter } from "src/interfaces/IMinter.sol";
import { IRewardsDistributor } from "src/interfaces/IRewardsDistributor.sol";
import {BlackholeLoanV2 as Loan} from "../src/Blackhole/BlackholeLoanV2.sol";
import { Loan as Loanv2 } from "../src/LoanV2.sol";
import { MockOdosRouterRL } from "./mocks/MockOdosRouter.sol";

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
 * @title BlackholeTest
 * @dev Test suite for blackhole venft deployment on Avalanche network
 * @notice Tests the integration of blackhole venft with the existing loan system
 */
contract BlackholeTest is Test {
    uint256 fork;
    

    // Avalanche network addresses
    IERC20 aero = IERC20(0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6);
    IUSDC usdc = IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IVotingEscrow votingEscrow = IVotingEscrow(0xEac562811cc6abDbB2c9EE88719eCA4eE79Ad763);
    IERC20 weth = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IVoter public voter = IVoter(0xE30D0C8532721551a51a9FeC7FB233759964d9e3);
    
    // Blackhole specific addresses (to be updated with actual addresses)
    address blackholeToken = address(0x0); // Placeholder for blackhole token
    address blackholeVotingEscrow = address(0x0); // Placeholder for blackhole voting escrow
    address blackholeVoter = address(0x0); // Placeholder for blackhole voter
    
    address[] pool = [address(0x000D436A430CF25c4eAaA3EFF031D2CEfdFaF4b1)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan;
    address owner;
    address user;
    uint256 tokenId = 989; // Test token ID

    uint256 expectedRewards = 1269895;

    function setUp() public {
        fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(76178925);
        
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        console.log("user", user);
        
        // Deploy using BlackholeDeploy for Avalanche network
        BlackholeDeploy deployer = new BlackholeDeploy();
        (loan, vault, ) = deployer.deploy();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();

        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();
        
        // Set default pools and weights after deployment
        vm.startPrank(owner);
        address[] memory defaultPools = new address[](1);
        defaultPools[0] = 0x000D436A430CF25c4eAaA3EFF031D2CEfdFaF4b1; // Use the working pool address
        uint256[] memory defaultWeights = new uint256[](1);
        defaultWeights[0] = 100e18;
        
        // Approve the default pool
        loan.setApprovedPools(defaultPools, true);
        // Set the default pools and weights
        loan.setDefaultPools(defaultPools, defaultWeights);
        vm.stopPrank();

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        // Deploy and set up MockOdosRouter
        address odosRouterAddress = loan.odosRouter();
        vm.allowCheatcodes(odosRouterAddress);
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        vm.etch(odosRouterAddress, address(mockRouter).code);
        MockOdosRouterRL(odosRouterAddress).initMock(address(this));

        vm.prank(address(user));
        voter.reset(tokenId);
    }

    /**
     * @dev Test that the owner is correctly set
     */
    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    /**
     * @dev Test maximum loan calculation for blackhole venft
     */
    function testMaxLoan() public {
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 80e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 5e6;
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        (maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 75e6);

        loan.increaseLoan(tokenId, 70e6);
        (maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 5e6);

        loan.increaseLoan(tokenId, 5e6);
        (maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 0);
        vm.stopPrank();
    }

    /**
     * @dev Test loan request functionality for blackhole venft
     */
    function testLoanRequest() public {
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 1e6;
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, user);

        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }

    /**
     * @dev Test loan increase functionality
     */
    function testIncreaseLoan() public {
        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.warp(block.timestamp+1);
        loan.vote(tokenId);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6, "User should have more than loan");

        assertEq(loan.activeAssets(),1e6, "ff");
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be 1e6");
        assertEq(borrower, user);

        vm.startPrank(user);
        loan.increaseLoan(tokenId, amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance> amount, "Balance should be more than amount");
        assertEq(borrower, user);
        assertEq(loan.activeAssets(),2e6, "ff");

        assertEq(usdc.balanceOf(address(user)), 2e6 + startingUserBalance, "User should have .02e6");
        assertEq(usdc.balanceOf(address(vault)), 98e6, "Loan should have 1e6");
    }

    /**
     * @dev Test full loan payoff functionality
     */
    function testLoanFullPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);

        uint256 amount = 1e6;

        assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0x4A930a63B13e6683a204Cb10Ef20F68310231459);

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        loan.setApprovedPools(manualPools, true);
        vm.stopPrank();
        vm.startPrank(user);

        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 1);

        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), 1e6+startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Loan should have 97e6");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan), "Loan should own token");

        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        vm.expectRevert();
        loan.claimCollateral(tokenId);
        loan.pay(tokenId, 0);
        // After loan is paid off, user can claim collateral directly
        loan.claimCollateral(tokenId);

        vm.stopPrank();


        assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");
    }




    function testIncreaseAmount() public {
        uint256 _tokenId = 989;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);

        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0x4A930a63B13e6683a204Cb10Ef20F68310231459);
        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        loan.setApprovedPools(manualPools, true);
        vm.stopPrank();

        vm.startPrank(_user);
        votingEscrow.approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        vm.stopPrank();

        vm.prank(0xAcA50A3A37D6F2ba49A9f9E3BE949C342AC4b8a7);
        IERC20(aero).transfer(address(user), 0);
        vm.stopPrank();

        vm.startPrank(address(user));
        IERC20(aero).approve(address(loan), 5e18);
        loan.increaseAmount(_tokenId, 5e18);
    }

    /**
     * @dev Test loan upgrade functionality
     */
    function testUpgradeLoan() public {
        vm.startPrank(loan.owner());
        Loan loanV2 = new Loan();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();
    }

    /**
     * @dev Test blackhole venft specific voting functionality
     */
    function testBlackholeUserVoting() public {
        uint256 _tokenId = 989;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);

        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0x4A930a63B13e6683a204Cb10Ef20F68310231459);
        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        loan.setApprovedPools(manualPools, true);
        vm.stopPrank();

        vm.startPrank(_user);
        votingEscrow.approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3 days + 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;
        
        loan.userVote(tokenIds, manualPools, manualWeights);
    }

    /**
     * @dev Test blackhole venft specific voting functionality
     */
    function testBlackholeVoting() public {
        uint256 _tokenId = 989;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);

        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0x4A930a63B13e6683a204Cb10Ef20F68310231459);
        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        loan.setApprovedPools(manualPools, true);
        vm.stopPrank();

        vm.startPrank(_user);
        votingEscrow.approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 333601);
        loan.vote(_tokenId);
    }

    /**
     * @dev Test blackhole venft rewards claiming using MockOdosRouter
     */
    function testBlackholeRewardsClaiming() public {
        uint256 _tokenId = 1011;
        address _user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(_user);
        voter.reset(_tokenId);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // Use MockOdosRouter - give user 100 USDC after swap
        uint256 swapOutputAmount = 100e6; // 100 USDC
        bytes memory data = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(aero),          // tokenIn
            address(usdc),          // tokenOut
            0,                      // amountIn (0 since we're mocking)
            swapOutputAmount,       // amountOut - 100 USDC
            address(loan)           // receiver
        );
        uint256[2] memory allocations = [swapOutputAmount, uint256(0)];

        address[] memory fees = new address[](4);
        fees[0] = 0xB6AC9192ED3F3d476F3e4692F5F87c7ca499bE78;
        fees[1] = 0xBED7aA4f2D9079A103f3927D2cC1736f2AAbFe2e;
        fees[2] = 0x8Df11e38735659922AE7E2c7783576BEbde40b25;
        fees[3] = 0x1718B43eB979F21de34534759A55f50E68D8B202;

        address[][] memory tokens = new address[][](4);

        // First array
        tokens[0] = new address[](2);
        tokens[0][0] = 0x09Fa58228bB791ea355c90DA1e4783452b9Bd8C3;
        tokens[0][1] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

        // Second array
        tokens[1] = new address[](5);
        tokens[1][0] = 0x09Fa58228bB791ea355c90DA1e4783452b9Bd8C3;
        tokens[1][1] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        tokens[1][2] = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
        tokens[1][3] = 0x6Aa38eDd7f32a28b7b2c2dc86fC5b0bF2aE61579;
        tokens[1][4] = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;

        // Third array
        tokens[2] = new address[](2);
        tokens[2][0] = 0x09Fa58228bB791ea355c90DA1e4783452b9Bd8C3;
        tokens[2][1] = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;

        // Fourth array
        tokens[3] = new address[](5);
        tokens[3][0] = 0x09Fa58228bB791ea355c90DA1e4783452b9Bd8C3;
        tokens[3][1] = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;
        tokens[3][2] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        tokens[3][3] = 0x6Aa38eDd7f32a28b7b2c2dc86fC5b0bF2aE61579;
        tokens[3][4] = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

        vm.prank(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA);
        uint256 rewards = loan.claim(_tokenId, fees, tokens, data, allocations);

        assertTrue(rewards > 0, "Should claim rewards");
        assertTrue(rewards >= 95e6, "Should have received close to 100 USDC (minus fees)");
    }

    /**
     * @dev Test blackhole venft merge functionality
     */
    function testBlackholeMerge() public {
        uint256 _tokenId = 989;
        address _user = votingEscrow.ownerOf(_tokenId);

        tokenId = 1011;


        vm.startPrank(_user);        
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), true, false);
        vm.stopPrank();
        
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        
        address _user2 = votingEscrow.ownerOf(tokenId);
        vm.prank(_user2);
        voter.reset(tokenId);
        vm.prank(_user2);
        votingEscrow.transferFrom(_user2, address(_user), tokenId);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        vm.startPrank(_user);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        console.log("msg.sender: %s", _user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);

        loan.merge(tokenId, _tokenId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertEq(votingEscrow.ownerOf(tokenId), address(0), "should be burnt");
    }

    /**
     * @dev Test blackhole venft specific configuration
     */
    function testBlackholeConfiguration() public {
        assertEq(loan.owner(), owner, "Owner should be set correctly");
        assertEq(address(loan._asset()), address(usdc), "Asset should be USDC");
        assertEq(address(loan._ve()), address(votingEscrow), "Voting escrow should be set");

    }
    /**
     * @dev Test blackhole venft with different increase percentages
     */
    function testBlackholeIncreasePercentages() public {
        uint256 _tokenId = 989;
        address _user = votingEscrow.ownerOf(_tokenId);
        
        vm.startPrank(_user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.stopPrank();
        
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3601);
        
        // Test different increase percentages
        uint256[] memory percentages = new uint256[](4);
        percentages[0] = 2500;  // 25%
        percentages[1] = 5000;  // 50%
        percentages[2] = 7500;  // 75%
        percentages[3] = 10000; // 100%
        
        for (uint256 i = 0; i < percentages.length; i++) {
            vm.startPrank(_user);
            loan.setIncreasePercentage(_tokenId, percentages[i]);
            vm.stopPrank();
            
            // Verify the percentage was set correctly
            // Note: This assumes there's a getter function for increase percentage
            // You may need to add this function to the loan contract
        }
    }


    /**
     * @dev Internal function to claim rewards (copied from existing test)
     */
    function _claimRewards(Loan _loan, uint256 _tokenId, address[] memory bribes, bytes memory tradeData, uint256[2] memory allocations) internal returns (uint256) {
        address[] memory pools = new address[](256); // Assuming a maximum of 256 pool votes
        uint256 index = 0;

        while (true) {
            try voter.poolVote(_tokenId, index) returns (address _pool) {
                pools[index] = _pool;
                index++;
            } catch {
                break; // Exit the loop when it reverts
            }
        }

        address[] memory voterPools = new address[](index);
        for (uint256 i = 0; i < index; i++) {
            voterPools[i] = pools[i];
        }
        address[] memory fees = new address[](voterPools.length);
        address[][] memory tokens = new address[][](voterPools.length);

        for (uint256 i = 0; i < voterPools.length; i++) {
            address gauge = voter.gauges(voterPools[i]);
            fees[i] = voter.feeDistributors(gauge);
            address[] memory token = new address[](2);
            token[0] = ICLGauge(voterPools[i]).token0();
            token[1] = ICLGauge(voterPools[i]).token1();
            address[] memory bribeTokens = new address[](bribes.length + 2);
            for (uint256 j = 0; j < bribes.length; j++) {
                bribeTokens[j] = bribes[j];
            }
            bribeTokens[bribes.length] = token[0];
            bribeTokens[bribes.length + 1] = token[1];
            tokens[i] = bribeTokens;
        }
        
        // log fees and tokens
        console.log("Fees and Tokens for Token ID %s", _tokenId);
        for (uint256 i = 0; i < fees.length; i++) {
            console.log("Fee %s: %s", i, fees[i]);
            for (uint256 j = 0; j < tokens[i].length; j++) {
                console.log("Token %s: %s", j, tokens[i][j]);
            }
        }

        vm.prank(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA);
        return _loan.claim(_tokenId, fees, tokens, tradeData, allocations);
    }



    function testSetToManualVoting() public {
        vm.skip(true); // set to manual voting is removed due to contract size limit
        uint256 fork3 = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork3);
        vm.rollFork(72429705);

        address loanContract = address(0x5122f5154DF20E5F29df53E633cE1ac5b6623558);

        Loan loanImpl = new Loan();
        address owner = Loan(loanContract).owner();
        vm.startPrank(owner);
        Loan(loanContract).upgradeToAndCall(address(loanImpl), new bytes(0));
        vm.stopPrank();

        uint256 _tokenId = 19615;
        (,,address _user,,,,uint256 voteTimestamp,,,,,,,) = Loan(loanContract)._loanDetails(_tokenId);
        assertNotEq(voteTimestamp, 0, "Vote timestamp should not be 0");

        vm.startPrank(_user);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId; 
        // set to automatic voting
        address[] memory pools = new address[](0);
        uint256[] memory weights = new uint256[](0);
        Loan(loanContract).userVote(tokenIds, pools, weights);
        (,,,,,,uint256 voteTimestampAfterAuto,,,,,,,) = Loan(loanContract)._loanDetails(_tokenId);
        assertEq(voteTimestampAfterAuto, 0, "Vote timestamp should be 0");

        // set to manual voting
        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0);
        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;
        Loan(loanContract).userVote(tokenIds, manualPools, manualWeights);
        (,,,,,,uint256 updatedVoteTimestamp,,,,,,,) = Loan(loanContract)._loanDetails(_tokenId);
        assertNotEq(updatedVoteTimestamp, 0, "Vote timestamp should not be 0");

        vm.warp(1764196188);
        bool successfulVote = Loan(loanContract).vote(_tokenId);
        (,,,,,,uint256 voteAfterAutomaticVoteTx,,,,,,,) = Loan(loanContract)._loanDetails(_tokenId);
        assertEq(voteAfterAutomaticVoteTx, updatedVoteTimestamp, "Vote timestamp should be the same as the updated vote timestamp");
        assertFalse(successfulVote, "Vote should be unsuccessful");


        // set back to automatic voting
        address[] memory automaticPools = new address[](0);
        uint256[] memory automaticWeights = new uint256[](0);
        Loan(loanContract).userVote(tokenIds, automaticPools, automaticWeights);
        (,,,,,,uint256 automaticVoteTimestamp,,,,,,,) = Loan(loanContract)._loanDetails(_tokenId);
        assertEq(automaticVoteTimestamp, 0, "Vote timestamp should be 0");

        successfulVote = Loan(loanContract).vote(_tokenId);
        (,,,,,,automaticVoteTimestamp,,,,,,,) = Loan(loanContract)._loanDetails(_tokenId);
        assertNotEq(automaticVoteTimestamp, updatedVoteTimestamp, "Vote timestamp should be the same as the updated vote timestamp");
        assertTrue(successfulVote, "Vote should be successful");

        // if not voted over 14 days, should revert
        vm.warp(1764874993);

        // set to manual voting
        vm.expectRevert();
        Loan(loanContract).userVote(tokenIds, manualPools, manualWeights);



        vm.stopPrank();
    }

}
