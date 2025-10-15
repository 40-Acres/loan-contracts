// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {XPharaohLoan} from "../src/Pharaoh/XPharaohLoan.sol";
import {XPharaohFacet} from "../src/facets/account/XPharaohFacet.sol";
import {IXLoan} from "../src/interfaces/IXLoan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IXVoter} from "src/interfaces/IXVoter.sol";
import {Vault} from "src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolTimeLibrary} from "src/libraries/ProtocolTimeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {XPharaohDeploy} from "../script/XPharaohDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {XPharaohUpgrade} from "../script/XPharaohDeploy.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";
import {IVoteModule} from "../src/interfaces/IVoteModule.sol";
import {IVoter} from "../src/interfaces/IVoter.sol";
import {PharaohLoan} from "../src/Pharaoh/PharaohLoan.sol";
import {PharaohLoanV2} from "../src/Pharaoh/PharaohLoanV2.sol";
import {ILoan} from "../src/interfaces/ILoan.sol";
import { Loan as Loanv2 } from "../src/LoanV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";

contract MockOdosRouterRL {
    address public testContract;

    address ODOS = 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC;
    address USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address PHAR = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address receiver) external returns (bool) {
        IERC20(tokenIn).transferFrom(receiver, address(this), amountIn);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(tokenOut).masterMinter(), receiver, amountOut));
        require(success, "mint fail");
        return true;
    }


    function executeSwapMultiOutput(uint256 amount1, uint256 amount2, address receiver) external returns (bool) {
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E).masterMinter(), receiver, amount1));
        require(success, "mint fail");

        (bool success2,) = testContract.call(abi.encodeWithSignature("mintRex(address,uint256)", receiver, amount2));
        require(success2, "mint rex fail");

        return true;
    }
}


interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(
        address minter,
        uint256 minterAllowedAmount
    ) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

/**
 * @title XPharaohTest
 * @dev Test contract for DiamondAccount Loan facet functionality
 */
contract XPharaohTest is Test {
    uint256 fork;

    IERC20 aero = IERC20(0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9);
    IUSDC usdc = IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IERC20 votingEscrow =
        IERC20(0xc93B315971A4f260875103F5DA84cB1E30f366Cc);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IXVoter public voter = IXVoter(0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7);
    address[] pool = [address(0x5cA009013F6B898D134b6798B336A4592f3B4aF2)];
    ProxyAdmin admin;
    address userAccount;

    address ODOS = 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC;
    address PHAR = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    // deployed contracts
    Vault vault;
    XPharaohLoan public loan;
    XPharaohFacet public loanFacet;
    address owner;
    address user;
    uint256 amount = 5e6;
    uint256 tokenId = 14054997634637524683;

    uint256 expectedRewards = 957174473;
    AccountConfigStorage accountConfigStorage;

    Swapper public swapper;

    // Account Factory system
    PortfolioFactory public portfolioFactory;


    function setUp() public {
        fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(70252438);
        owner = vm.addr(0x123);
        user = 0x97BE22DBb49C88451fBd1099F59EED963d9d8A12;
        XPharaohDeploy deployer = new XPharaohDeploy();
        (XPharaohLoan loanV2, Vault deployedVault, Swapper deployedSwapper, AccountConfigStorage _accountConfigStorage, PortfolioFactory _portfolioFactory) = deployer.deploy();
        accountConfigStorage = _accountConfigStorage;
        loan = XPharaohLoan(address(loanV2));
        vault = deployedVault;
        swapper = deployedSwapper;
        


        // Send PHAR token to the user
        vm.prank(0x972698bF61E2377B5c45B3038D85d04981ddb48c);
        aero.transfer(user, 100e18);

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        loan.setPortfolioFactory(address(portfolioFactory));
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Approve the pool for voting
        address[] memory pools = new address[](1);
        pools[0] = address(0x5cA009013F6B898D134b6798B336A4592f3B4aF2);
        loan.setApprovedPools(pools, true);
        vm.stopPrank();

        // Deploy the XPharaohFacet
        // The test contract is the owner of the simple AccountConfigStorage
        vm.prank(IOwnable(address(accountConfigStorage)).owner());
        accountConfigStorage.setApprovedContract(address(loan), true);
        loanFacet = new XPharaohFacet(address(portfolioFactory), address(accountConfigStorage));
        vm.prank(IOwnable(address(accountConfigStorage)).owner());
        accountConfigStorage.setAuthorizedCaller(address(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA), true);

        // Register XPharaohFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](8);
        loanSelectors[0] = 0xdbbe2f11; // xPharRequestLoan(uint256,address,uint256,uint8,uint256,address,bool)
        loanSelectors[1] = 0x6514a9ff; // xPharIncreaseLoan(address,uint256)
        loanSelectors[2] = 0x100228bb; // xPharIncreaseCollateral(address,uint256)
        loanSelectors[3] = 0x7d9b5dc7; // xPharClaimCollateral(address,uint256)
        loanSelectors[4] = 0x31f84426; // xPharVote(address)
        loanSelectors[5] = 0xafe53449; // xPharUserVote(address,address[],uint256[])
        loanSelectors[6] = 0x574b41f0; // xPharClaim(address,address[],address[][],bytes,uint256[2])
        loanSelectors[7] = 0x73aa54b2; // xPharProcessRewards(address[],address[][],bytes)
        // Get the FacetRegistry from the PortfolioFactory
        FacetRegistry facetRegistry = FacetRegistry(
            portfolioFactory.facetRegistry()
        );
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "XPharaohFacet"
        );

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        vm.stopPrank();
        vm.startPrank(user);

        userAccount = portfolioFactory.portfolioOf(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.portfolioOf(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            
            vm.startPrank(user); // Resume user prank
        }

      
        IERC20(0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9).approve(address(userAccount), type(uint256).max);
        vm.stopPrank();



        // USDC minting for tests and mock Odos setup at canonical address
        
        vm.prank(IUSDC(usdc).masterMinter());
        MockOdosRouterRL mock = new MockOdosRouterRL();
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);
        MockOdosRouterRL(ODOS).initMock(address(this));
        vm.prank(0x972698bF61E2377B5c45B3038D85d04981ddb48c);
        IERC20(PHAR).transfer(address(this), 10000e18);
    }


    // helper for mock to mint USDC to a recipient
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        usdc.mint(to, amount);
    }

    // helper for mock to mint PHAR to a recipient
    function mintRex(address to, uint256 amount) external {
        aero.transfer(to, amount);
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    /**
     * @dev Test the getMaxLoan functionality through the XPharaohFacet
     * This replicates the testGetMaxLoan test from LoanTest but uses the XPharaohFacet
     */
    function testGetMaxLoan() public {
        // Test initial max loan through the facet
        (uint256 maxLoan, ) = loan.getMaxLoan(user);
        assertEq(maxLoan, 0);


        // log users _asset balance
        uint256 userAssetBalance = IERC20(loan._vaultAsset()).balanceOf(user);
        vm.startPrank(user);
        uint256 amount = 5e6;
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );

        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._vaultAsset()).balanceOf(user),
            userAssetBalance + amount
        );

        // the tokenId should be owned by the user account after requesting a loan
        // assertEq(votingEscrow.balanceOf(address(userAccount)), tokenId, "Voting escrow balance should be amount");

        // Test max loan after requesting a loan through the facet
        (maxLoan, ) = loan.getMaxLoan(userAccount);
        assertEq(maxLoan, 75e6);

        // Test max loan after increasing loan through the direct contract
        XPharaohFacet(userAccount).xPharIncreaseLoan(address(loan), 70e6);
        (maxLoan, ) = loan.getMaxLoan(userAccount);
        assertEq(maxLoan, 5e6, "Max loan should be 5e6");
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._vaultAsset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6
        );

        // Test max loan after maxing out the loan through the direct contract
        XPharaohFacet(userAccount).xPharIncreaseLoan(address(loan), 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._vaultAsset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6 + 5e6
        );
        (maxLoan, ) = loan.getMaxLoan(user);
        assertEq(maxLoan, 0);
        vm.stopPrank();
    }

    /**
     * @dev Test loan request through the facet
     */
    function testLoanRequest() public {
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.portfolioOf(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.portfolioOf(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank

            vm.startPrank(user); // Resume user prank
        }

        // IERC721(address(votingEscrow)).transferFrom(
        //     user,
        //     address(userAccount),
        //     tokenId
        // );
        vm.stopPrank();

        vm.startPrank(user);
        uint256 amount = 1e6;
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        assertTrue(usdc.balanceOf(address(user)) >= 1e6, "User should have more than 1e6");
        assertTrue(usdc.balanceOf(address(vault)) < 100e6, "Vault should have less than 100e6");

        // Verify the loan details through the facet
        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertTrue(balance >= amount, "Balance should be more than amount");
        assertEq(borrower, address(userAccount));

    }

    /**
     * @dev Test loan increase through the facet
     */
    function testIncreaseLoan() public {
        uint256 amount = 1e6;
        uint256 startingUserBalance = usdc.balanceOf(address(user));

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.portfolioOf(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.portfolioOf(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            vm.startPrank(user); // Resume user prank
        }

        // IERC721(address(votingEscrow)).transferFrom(
        //     user,
        //     address(userAccount),
        //     tokenId
        // );
        vm.stopPrank();

        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.roll(block.number + 1);
        loan.vote(user);
        vm.stopPrank();

        assertTrue(usdc.balanceOf(address(user)) >= 1e6, "User should have more than loan");
        assertEq(loan.activeAssets(), 1e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertTrue(balance >= amount, "Balance should be more than amount");
        assertEq(borrower, address(userAccount));

        // Test increasing the loan through the facet
        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharIncreaseLoan(address(loan), amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(userAccount);
        assertTrue(balance >= amount, "Balance2 should be more than amount");
        assertEq(borrower, address(userAccount));
        assertEq(loan.activeAssets(), 2e6);

        assertEq(usdc.balanceOf(address(user)), 2e6 + startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 98e6);
    }

    /**
     * @dev Test vote functionality
     */
    function testVote() public {
        uint256 amount = 1e6;

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.portfolioOf(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.portfolioOf(user);
            vm.stopPrank();
            vm.startPrank(user);
        }

        // IERC721(address(votingEscrow)).transferFrom(
        //     user,
        //     address(userAccount),
        //     tokenId
        // );
        vm.stopPrank();

        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        // set user to auto vote
        // vm.startPrank(user);
        // uint256[] memory tokenIds = new uint256[](1);
        // tokenIds[0] = tokenId;
        // address[] memory pools = new address[](0);
        // uint256[] memory weights = new uint256[](0);
        // XPharaohFacet(userAccount).userVote(
        //     address(loan),
        //     tokenIds,
        //     pools,
        //     weights
        // );
        // vm.stopPrank();

        // warp time to the last day of the epoch
        vm.roll(block.number + 1);
        vm.warp(1758751302);
        vm.startPrank(user);
        bool voteResult = XPharaohFacet(userAccount).xPharVote(address(loan));
        vm.stopPrank();

        // Verify that vote was successful
        assertTrue(voteResult, "Vote should have been successful");
    }

    /**
     * @dev Test userVote functionality
     */
    function testUserVote() public {
        uint256 amount = 1e6;

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.portfolioOf(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.portfolioOf(user);
            vm.stopPrank();
            vm.startPrank(user);
        }

        // IERC721(address(votingEscrow)).transferFrom(
        //     user,
        //     address(userAccount),
        //     tokenId
        // );
        vm.stopPrank();

        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        // Test userVote function with empty arrays (resets to automatic voting)
        // vm.startPrank(user);
        // uint256[] memory tokenIds = new uint256[](1);
        // tokenIds[0] = tokenId;
        address[] memory pools = new address[](0);
        uint256[] memory weights = new uint256[](0);
        // XPharaohFacet(userAccount).userVote(
        //     address(loan),
        //     tokenIds,
        //     pools,
        //     weights
        // );
        // vm.stopPrank();

        // fast forward one week and one block
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 weeks);
        // get the weight of tokenId

        // Test userVote function with actual pools and weights
        vm.startPrank(user);
        pools = new address[](1);
        pools[0] = address(0x5cA009013F6B898D134b6798B336A4592f3B4aF2);
        weights = new uint256[](1);
        weights[0] = 100e18; // 100% weight
        XPharaohFacet(userAccount).xPharUserVote(
            address(loan),
            pools,
            weights
        );
        vm.stopPrank();
    }

    /**
     * @dev Test loan payoff through the facet
     */
    function testLoanPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);
        vm.stopPrank();

        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.portfolioOf(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.portfolioOf(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            vm.startPrank(user); // Resume user prank
        }

        // IERC721(address(votingEscrow)).transferFrom(
        //     user,
        //     address(userAccount),
        //     tokenId
        // );
        vm.stopPrank();

        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(user)), 1e6 + startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6);

        // Test payoff through the facet
        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        loan.pay(userAccount, 0);


        XPharaohFacet(userAccount).xPharClaimCollateral(address(loan), 100e18);

        // loan details should be 0
        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertEq(balance, 0, "Balance should be 0");
        assertEq(borrower, address(0), "Borrower should be 0");
        vm.stopPrank();
    }


    /**
     * @dev Test loan payoff through the facet
     */
    function testClaimCollateral() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);
        vm.stopPrank();

        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.portfolioOf(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.portfolioOf(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            vm.startPrank(user); // Resume user prank
        }

        // IERC721(address(votingEscrow)).transferFrom(
        //     user,
        //     address(userAccount),
        //     tokenId
        // );
        vm.stopPrank();

        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(user)), 1e6 + startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6);

        // try to claim collateral which should fail
        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharClaimCollateral(address(loan), 1e18);


        uint256 xPharBalance = 100e18;
        vm.expectRevert();
        XPharaohFacet(userAccount).xPharClaimCollateral(address(loan), xPharBalance);


        vm.expectRevert();
        XPharaohFacet(userAccount).xPharClaimCollateral(address(loan), xPharBalance - 1);

        XPharaohFacet(userAccount).xPharClaimCollateral(address(loan), 5e18);
        usdc.approve(address(loan), 5e6);
        loan.pay(userAccount, 0);

        XPharaohFacet(userAccount).xPharClaimCollateral(address(loan), 5e18);

        XPharaohFacet(userAccount).xPharClaimCollateral(address(loan), 89e18);

        // loan details should be 0
        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertEq(balance, 0, "Balance should be 0");
        assertEq(borrower, address(0), "Borrower should be 0");
        vm.stopPrank();
    }

    function testPortfolioFactory() public {
        // create a new account
        address _user = address(0x123);
        portfolioFactory.createAccount(_user);
        address newAccount = portfolioFactory.portfolioOf(_user);
        assertEq(portfolioFactory.ownerOf(newAccount), _user, "New account owner should be the user");
        assertEq(portfolioFactory.portfolioOf(_user), newAccount, "New account should be the user account");
        assertEq(portfolioFactory.getAllPortfolios().length, 2, "There should be 2 account");
        assertEq(portfolioFactory.getPortfoliosLength(), 2, "There should be 2 account");
        assertEq(portfolioFactory.getPortfolio(0), userAccount, "New account should be the first account");
        assertEq(portfolioFactory.getPortfolio(1), newAccount, "New account should be the second account");
    }

    function testClaim() public {
        uint256 amount = 1e6;
        uint256 startingUserBalance = usdc.balanceOf(address(user));


        // Request loan through the user account
        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.PayToOwner,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        // Verify loan was created
        (uint256 balance, ) = loan.getLoanDetails(userAccount);
        assertTrue(
            balance >= amount,
            "Loan balance should be at least the requested amount"
        );

        // Verify the user received the loan
        uint256 endingUserBalance = usdc.balanceOf(address(user));
        assertTrue(
            endingUserBalance > startingUserBalance,
            "User should have received loan funds"
        );

        // Test that the user account can interact with the loan
        vm.startPrank(user);

        // Test that the user account can vote (this tests the user account integration)
        address[] memory pools = new address[](1);
        pools[0] = address(0x5cA009013F6B898D134b6798B336A4592f3B4aF2);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100000000000000000000; // 100 tokens



        // ensure Voted(user, weight, pools[0]) is emitted from the voter contract
        vm.expectEmit(true, true, true, true);
        emit IXVoter.Voted(userAccount, 100e18, pools[0]);
        // This should work through the user account
        XPharaohFacet(userAccount).xPharUserVote(
            address(loan),
            pools,
            weights
        );
        vm.stopPrank();

        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(userAccount));
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwapMultiOutput.selector,
            10e6,
            21919478169540, // send less to account for slippage
            address(userAccount)
        );

        uint256[2] memory allocations = [
            uint256(41349),
            uint256(21919478169541)
        ];
        address[] memory bribes = new address[](1);
        bribes[0] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        uint256 rewards = _claimRewards(
            Loan(userAccount),
            bribes,
            tradeData,
            allocations
        );
        // loan balance should be 0
        (balance, ) = loan.getLoanDetails(userAccount);
        assertEq(balance, 0, "Balance should be 0");
    }


    function testClaimWithPreferredToken() public {

        address owner = loan.owner();
        uint256 amount = 0;
        vm.prank(owner);
        loan.setApprovedToken(address(aero), true);
        // Request loan through the user account
        vm.startPrank(user);
        XPharaohFacet(userAccount).xPharRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            0,
            IXLoan.ZeroBalanceOption.PayToOwner,
            0,
            address(aero),
            false
        );
        vm.stopPrank();

        uint256 startingUserBalance = aero.balanceOf(address(user));
        uint256 startingPortfolioBalance = aero.balanceOf(address(portfolioFactory));

        // Verify loan was created
        (uint256 balance, ) = loan.getLoanDetails(userAccount);
        assertTrue(
            balance >= amount,
            "Loan balance should be at least the requested amount"
        );


        // Test that the user account can interact with the loan
        vm.startPrank(user);

        // Test that the user account can vote (this tests the user account integration)
        address[] memory pools = new address[](1);
        pools[0] = address(0x5cA009013F6B898D134b6798B336A4592f3B4aF2);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100000000000000000000; // 100 tokens



        // ensure Voted(user, weight, pools[0]) is emitted from the voter contract
        vm.expectEmit(true, true, true, true);
        emit IXVoter.Voted(userAccount, 100e18, pools[0]);
        // This should work through the user account
        XPharaohFacet(userAccount).xPharUserVote(
            address(loan),
            pools,
            weights
        );
        vm.stopPrank();

        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(userAccount));
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwapMultiOutput.selector,
            1,
            25919478169541, // send less to account for slippage
            address(userAccount)
        );

        uint256[2] memory allocations = [
            uint256(25919478169541),
            uint256(21919478169541)
        ];
        address[] memory bribes = new address[](1);
        bribes[0] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        uint256 rewards = _claimRewards(
            Loan(userAccount),
            bribes,
            tradeData,
            allocations
        );

        // Verify the user received the loan
        uint256 endingUserBalance = aero.balanceOf(address(user));
        console.log("endingUserBalance", endingUserBalance);
        console.log("startingUserBalance", startingUserBalance);
        uint256 endingPortfolioBalance = aero.balanceOf(address(portfolioFactory));
        console.log("endingPortfolioBalance", endingPortfolioBalance);
        console.log("startingPortfolioBalance", startingPortfolioBalance);
        assertEq(
            endingPortfolioBalance,startingPortfolioBalance,
            "Portfolio should not have received loan funds"
        );
        assertTrue(
            endingUserBalance > startingUserBalance,
            "User should have received loan funds"
        );

        // loan balance should be 0
        (balance, ) = loan.getLoanDetails(userAccount);
        assertEq(balance, 0, "Balance should be 0");
    }
    
    function _claimRewards(
        Loan _loan,
        address[] memory bribes,
        bytes memory tradeData,
        uint256[2] memory allocations
    ) internal returns (uint256) {

       address[] memory voterPools = voter.getAllUserVotedPoolsPerPeriod(address(user), 2908);

        address[] memory fees = new address[](voterPools.length);
        address[][] memory tokens = new address[][](voterPools.length);

        for (uint256 i = 0; i < voterPools.length; i++) {
            address gauge = voter.gaugeForPool(voterPools[i]);
            fees[i] = voter.feeDistributorForGauge(gauge);
            // 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, 0xacA92E438df0B2401fF60dA7E4337B687a2435DA, 0xA219439258ca9da29E9Cc4cE5596924745e12B93, 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f
            address[] memory tokenIds = new address[](4);
            tokenIds[0] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
            tokenIds[1] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;
            tokenIds[2] = 0xA219439258ca9da29E9Cc4cE5596924745e12B93;
            tokenIds[3] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
            tokens[i] = tokenIds;
        }
        bytes memory data = "";
        vm.startPrank(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA);
        uint256 result = XPharaohFacet(address(_loan)).xPharClaim(
            address(loan), // Use the actual loan contract address
            fees,
            tokens,
            tradeData,
            allocations
        );
        vm.stopPrank();
        return result;
    }
}

