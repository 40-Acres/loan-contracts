// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {EtherexLoan} from "../src/Etherex/EtherexLoan.sol";
import {XRexFacet} from "../src/facets/account/XRexFacet.sol";
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
import {EtherexDeploy} from "../script/EtherexDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {EtherexUpgrade} from "../script/EtherexDeploy.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";
import {IVoteModule} from "../src/interfaces/IVoteModule.sol";
import {FortyAcresPortfolioAccount} from "../src/accounts/FortyAcresPortfolioAccount.sol";


contract MockOdosRouterRL {
    address public testContract;

    address ODOS = 0x2d8879046f1559E53eb052E949e9544bCB72f414;
    address USDC = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
    address REX = 0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4;
    
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address receiver) external returns (bool) {
        IERC20(tokenIn).transferFrom(receiver, address(this), amountIn);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(tokenOut).masterMinter(), receiver, amountOut));
        require(success, "mint fail");
        return true;
    }


    function executeSwapMultiOutput(uint256 amount1, uint256 amount2, address receiver) external returns (bool) {
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(0x176211869cA2b568f2A7D4EE941E073a821EE1ff).masterMinter(), receiver, amount1));
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
 * @title EtherexTest
 * @dev Test contract for DiamondAccount Loan facet functionality
 */
contract EtherexTest is Test {
    uint256 fork;

    IERC20 aero = IERC20(0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4);
    IUSDC usdc = IUSDC(0x176211869cA2b568f2A7D4EE941E073a821EE1ff);
    IERC20 votingEscrow =
        IERC20(0xc93B315971A4f260875103F5DA84cB1E30f366Cc);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IXVoter public voter = IXVoter(0x942117Ec0458a8AA08669E94B52001Bd43F889C1);
    address[] pool = [address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e)];
    ProxyAdmin admin;
    address userAccount;

    address ODOS = 0x2d8879046f1559E53eb052E949e9544bCB72f414;
    address REX = 0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4;
    // deployed contracts
    Vault vault;
    EtherexLoan public loan;
    XRexFacet public loanFacet;
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
        fork = vm.createFork(vm.envString("LINEA_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(23961806);
        owner = vm.addr(0x123);
        user = 0x97BE22DBb49C88451fBd1099F59EED963d9d8A12;
        EtherexDeploy deployer = new EtherexDeploy();
        (EtherexLoan loanV2, Vault deployedVault, Swapper deployedSwapper, AccountConfigStorage _accountConfigStorage, PortfolioFactory _portfolioFactory) = deployer.mock();
        accountConfigStorage = _accountConfigStorage;
        loan = EtherexLoan(address(loanV2));
        vault = deployedVault;
        swapper = deployedSwapper;
        portfolioFactory = _portfolioFactory;


        // Send REX token to the user
        vm.prank(0x1C1002aB527289dDda9a41bd49140B978d3B6303);
        aero.transfer(user, 100e18);

        
        vm.startPrank(IOwnable(address(loan)).owner());
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Approve the pool for voting
        address[] memory pools = new address[](1);
        pools[0] = address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e);
        loan.setApprovedPools(pools, true);
        vm.stopPrank();

        // Deploy the XRexFacet
        // The test contract is the owner of the simple AccountConfigStorage
        vm.prank(IOwnable(address(_accountConfigStorage)).owner());
        _accountConfigStorage.setApprovedContract(address(loan), true);
        vm.prank(IOwnable(address(_accountConfigStorage)).owner());
        _accountConfigStorage.setAuthorizedCaller(address(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA), true);

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

      
        IERC20(0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4).approve(address(userAccount), type(uint256).max);
        vm.stopPrank();



        // USDC minting for tests and mock Odos setup at canonical address
        
        vm.prank(IUSDC(usdc).masterMinter());
        MockOdosRouterRL mock = new MockOdosRouterRL();
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);
        MockOdosRouterRL(ODOS).initMock(address(this));
        vm.prank(0x3f6177CA0b041B1a469F11261f8a8b007633ed48);
        IERC20(REX).transfer(address(this), 10000e18);
    }

    // helper for mock to mint USDC to a recipient
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        usdc.mint(to, amount);
    }

    // helper for mock to mint REX to a recipient
    function mintRex(address to, uint256 amount) external {
        aero.transfer(to, amount);
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    /**
     * @dev Test the getMaxLoan functionality through the XRexFacet
     * This replicates the testGetMaxLoan test from LoanTest but uses the XRexFacet
     */
    function testGetMaxLoan() public {
        // Test initial max loan through the facet
        (uint256 maxLoan, ) = loan.getMaxLoan(user);
        assertEq(maxLoan, 0);


        // log users _asset balance
        uint256 userAssetBalance = IERC20(loan._vaultAsset()).balanceOf(user);
        vm.startPrank(user);
        uint256 amount = 5e6;
        XRexFacet(userAccount).xRexRequestLoan(
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
        XRexFacet(userAccount).xRexIncreaseLoan(address(loan), 70e6);
        (maxLoan, ) = loan.getMaxLoan(userAccount);
        assertEq(maxLoan, 5e6, "Max loan should be 5e6");
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._vaultAsset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6
        );

        // Test max loan after maxing out the loan through the direct contract
        XRexFacet(userAccount).xRexIncreaseLoan(address(loan), 5e6);
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
        XRexFacet(userAccount).xRexRequestLoan(
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
        XRexFacet(userAccount).xRexRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.roll(block.number + 1);
        vm.stopPrank();

        assertTrue(usdc.balanceOf(address(user)) >= 1e6, "User should have more than loan");
        assertEq(loan.activeAssets(), 1e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertTrue(balance >= amount, "Balance should be more than amount");
        assertEq(borrower, address(userAccount));

        // Test increasing the loan through the facet
        vm.startPrank(user);
        XRexFacet(userAccount).xRexIncreaseLoan(address(loan), amount);
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
        XRexFacet(userAccount).xRexRequestLoan(
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
        // XRexFacet(userAccount).userVote(
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
        bool voteResult = XRexFacet(userAccount).xRexVote(address(loan));
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
        XRexFacet(userAccount).xRexRequestLoan(
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
        // XRexFacet(userAccount).userVote(
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
        pools[0] = address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e);
        weights = new uint256[](1);
        weights[0] = 100e18; // 100% weight
        XRexFacet(userAccount).xRexUserVote(
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

        uint256 zbalance = IERC20(aero).balanceOf(user);
        XRexFacet(userAccount).xRexRequestLoan(
            zbalance,
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




        uint256 votingBalance = IVoteModule(address(0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1)).balanceOf(address(userAccount));
        XRexFacet(userAccount).xRexClaimCollateral(address(loan), votingBalance);

        // loan details should be 0
        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertEq(balance, 0, "Balance should be 0");

        assertEq(borrower, address(0), "Borrower should be 0");


        uint256 endingVotingBalance = IVoteModule(address(0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1)).balanceOf(address(userAccount));
        assertEq(endingVotingBalance, 0, "endingVotingBalance should be 0");

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
        uint256 startingBalance = IERC20(aero).balanceOf(user);
        XRexFacet(userAccount).xRexRequestLoan(
            startingBalance,
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
        XRexFacet(userAccount).xRexClaimCollateral(address(loan), 1e18);


        uint256 xRexBalance = IVoteModule(address(0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1)).balanceOf(address(userAccount));
        vm.expectRevert();
        XRexFacet(userAccount).xRexClaimCollateral(address(loan), xRexBalance);


        vm.expectRevert();
        XRexFacet(userAccount).xRexClaimCollateral(address(loan), xRexBalance - 1);

        XRexFacet(userAccount).xRexClaimCollateral(address(loan), 5e18);
        usdc.approve(address(loan), 5e6);
        loan.pay(userAccount, 0);

        xRexBalance = IVoteModule(address(0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1)).balanceOf(address(userAccount));
        XRexFacet(userAccount).xRexClaimCollateral(address(loan), xRexBalance/2);
        xRexBalance = IVoteModule(address(0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1)).balanceOf(address(userAccount));

        XRexFacet(userAccount).xRexClaimCollateral(address(loan), xRexBalance);

        // loan details should be 0
        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertEq(balance, 0, "Balance should be 0");
        assertEq(borrower, address(0), "Borrower should be 0");
        vm.stopPrank();

        assertEq(
            IERC20(aero).balanceOf(user)+1, // add one to account for rounding
            startingBalance,
            "User should have starting balance"
        );
    }

    function testPortfolioFactory() public {
        // create a new account
        address _user = address(0x123);
        portfolioFactory.createAccount(_user);
        address newAccount = portfolioFactory.portfolioOf(_user);
        assertEq(portfolioFactory.ownerOf(newAccount), _user, "New account owner should be the user");
        assertEq(portfolioFactory.portfolioOf(_user), newAccount, "Portfolio of user should be the new account");
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
        XRexFacet(userAccount).xRexRequestLoan(
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
        pools[0] = address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100000000000000000000; // 100 tokens



        // ensure Voted(user, weight, pools[0]) is emitted from the voter contract
        vm.expectEmit(true, true, true, true);
        emit IXVoter.Voted(userAccount, 109717434395951894051, pools[0]);
        // This should work through the user account
        XRexFacet(userAccount).xRexUserVote(
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
        bribes[0] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;
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
            // 0x176211869cA2b568f2A7D4EE941E073a821EE1ff, 0xacA92E438df0B2401fF60dA7E4337B687a2435DA, 0xA219439258ca9da29E9Cc4cE5596924745e12B93, 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f
            address[] memory tokenIds = new address[](4);
            tokenIds[0] = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
            tokenIds[1] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;
            tokenIds[2] = 0xA219439258ca9da29E9Cc4cE5596924745e12B93;
            tokenIds[3] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
            tokens[i] = tokenIds;
        }
        bytes memory data = "";
        vm.startPrank(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA);
        uint256 result = XRexFacet(address(_loan)).xRexClaim(
            address(loan), // Use the actual loan contract address
            fees,
            tokens,
            tradeData,
            allocations
        );
        vm.stopPrank();
        return result;
    }

    function testXRexClaimWithSpecificData() public {
        vm.skip(true);
                // Set up the fork to the specific block
        uint256 fork = vm.createFork(vm.envString("LINEA_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24382375);
        
        // Use the production loan contract
        address productionLoan = 0xCca5628DF6e5B16a1610d62467df34E07317A891;
        portfolioFactory = PortfolioFactory(0x2155F306d2806d745427A3E04721e8Cf6F8327dd);
        
        // Use the existing user account that already has a loan
        address userAccount = 0x7A841521878F484438F40691D91d8FcCEa4e8577;
        
        // Verify the user account has a loan on the production contract
        (uint256 balance, ) = IXLoan(productionLoan).getLoanDetails(userAccount);
        assertTrue(balance > 0, "User account should have an existing loan");
        
        // Create the upgrade contract first
        EtherexUpgrade upgrade = new EtherexUpgrade();
        
        // Get the facet registry from the portfolio factory
        FacetRegistry facetRegistry = FacetRegistry(portfolioFactory.facetRegistry());
        
        // Get the current owner of the facet registry
        address facetRegistryOwner = facetRegistry.owner();
        
        // Mock the owner for the facet registry
        vm.startPrank(facetRegistryOwner);
        
        // Use the existing EtherexUpgrade to replace the facet
        upgrade.upgrade();
        
        // Set up the specific claim data as provided
        address[] memory fees = new address[](4);
        fees[0] = 0x618BDec445317ee8b881303624ED13f9c0Ccd094;
        fees[1] = 0xE949D829a2b9C4EEb61796fB9f6f7424a2097D3b;
        fees[2] = 0x6868bAa12388b97EE289707D1C21972385432088;
        fees[3] = 0x16b0Be9F403e3Ec0d4f7D44D85D5B15e2c7Af15D;

        address[][] memory tokens = new address[][](4);
        tokens[0] = new address[](4);
        tokens[0][0] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;
        tokens[0][1] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        tokens[0][2] = 0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4;
        tokens[0][3] = 0x5FBDF89403270a1846F5ae7D113A989F850d1566;

        tokens[1] = new address[](3);
        tokens[1][0] = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
        tokens[1][1] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        tokens[1][2] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;

        tokens[2] = new address[](2);
        tokens[2][0] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;
        tokens[2][1] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;

        tokens[3] = new address[](3);
        tokens[3][0] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;
        tokens[3][1] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        tokens[3][2] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;

        bytes memory tradeData = hex"84a7f3dd05010001fb66e944021bf915cfb4dac2b20653930bf7d35a062d8dd054ece800011789e0043623282d5dcc7f213d703c6d8bafbb0408bfebb362e0d77e2e00010b629fe58d1b8702c1cdb75d93a7851b7591778c0001e5d7c2a44ffddf6b295a15c148167daaaf5cf34f061aa191cf76a500000001e4eeb461ad1e4ef8b8ef71a33694ccd84af051c4058e00f0cc72000000015fbdf89403270a1846f5ae7d113a989f850d1566062fd42043e6d400000001aca92e438df0b2401ff60da7e4337b687a2435da03013f5200000001176211869ca2b568f2a7d4ee941e073a821ee1ff0405f6cd2100017a841521878f484438f40691d91d8fccea4e8577000000000902060b060805010102000305010003040032040a0501050600080a0501070800020d0501090a00ff0000000000000000000000000000000000000000000000002a4769bea90d379c96cdff7addee77b87016166e5fbdf89403270a1846f5ae7d113a989f850d15660b629fe58d1b8702c1cdb75d93a7851b7591778c1789e0043623282d5dcc7f213d703c6d8bafbb04b0091b7e234a67182712925ee4ef48c11bce6159e4eeb461ad1e4ef8b8ef71a33694ccd84af051c409666eaf650dc52cece84b1bcd2dd78997d239c7aca92e438df0b2401ff60da7e4337b687a2435dae1d9617c4dd72589733dd1d418854804d5c14437e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000000000000000000000000000";

        uint256[2] memory allocations = [uint256(556336), uint256(0)];

        // Record balances before the claim
        uint256 userUsdcBalanceBefore = usdc.balanceOf(userAccount);
        uint256 userRexBalanceBefore = aero.balanceOf(userAccount);

        console.log("User USDC balance before claim:", userUsdcBalanceBefore);
        console.log("User REX balance before claim:", userRexBalanceBefore);

        // Call xRexClaim with the specific data
        vm.startPrank(0xf161e7c79e0c0A3FD8D75A05A53A04E05B2034d3);
        uint256 result = XRexFacet(userAccount).xRexClaim(
            productionLoan,
            fees,
            tokens,
            tradeData,
            allocations
        );
        vm.stopPrank();

        // Record balances after the claim
        uint256 userUsdcBalanceAfter = usdc.balanceOf(userAccount);
        uint256 userRexBalanceAfter = aero.balanceOf(userAccount);

        // loan balance should have changed

        console.log("balance", balance);
        (uint256 afterBalance,) =  IXLoan(productionLoan).getLoanDetails(userAccount);
        console.log("afterBalance", afterBalance);
        assertTrue(afterBalance < balance, "Loan balance should have decreased");

        // Verify that the claim was successful
        assertTrue(result > 0, "Claim should return a positive result");
     
    }



    function testXRexClaimWithTopup() public {
        vm.skip(true);
        // Set up the fork to the specific block
        uint256 fork = vm.createFork(vm.envString("LINEA_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24382375);
        
        // Use the production loan contract
        address productionLoan = 0xCca5628DF6e5B16a1610d62467df34E07317A891;
        portfolioFactory = PortfolioFactory(0x2155F306d2806d745427A3E04721e8Cf6F8327dd);
        
        // Use the existing user account that already has a loan
        address userAccount = 0x7A841521878F484438F40691D91d8FcCEa4e8577;

        vm.prank(userAccount);
        IXLoan(productionLoan).setTopUp(true);
        
        // Verify the user account has a loan on the production contract
        (uint256 balance, ) = IXLoan(productionLoan).getLoanDetails(userAccount);
        assertTrue(balance > 0, "User account should have an existing loan");
        
        // Create the upgrade contract first
        EtherexUpgrade upgrade = new EtherexUpgrade();
        
        // Get the facet registry from the portfolio factory
        FacetRegistry facetRegistry = FacetRegistry(portfolioFactory.facetRegistry());
        
        // Get the current owner of the facet registry
        address facetRegistryOwner = facetRegistry.owner();
        
        // Mock the owner for the facet registry
        vm.startPrank(facetRegistryOwner);
        
        // Use the existing EtherexUpgrade to replace the facet
        upgrade.upgrade();
        
        // Set up the specific claim data as provided
        address[] memory fees = new address[](4);
        fees[0] = 0x618BDec445317ee8b881303624ED13f9c0Ccd094;
        fees[1] = 0xE949D829a2b9C4EEb61796fB9f6f7424a2097D3b;
        fees[2] = 0x6868bAa12388b97EE289707D1C21972385432088;
        fees[3] = 0x16b0Be9F403e3Ec0d4f7D44D85D5B15e2c7Af15D;

        address[][] memory tokens = new address[][](4);
        tokens[0] = new address[](4);
        tokens[0][0] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;
        tokens[0][1] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        tokens[0][2] = 0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4;
        tokens[0][3] = 0x5FBDF89403270a1846F5ae7D113A989F850d1566;

        tokens[1] = new address[](3);
        tokens[1][0] = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
        tokens[1][1] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        tokens[1][2] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;

        tokens[2] = new address[](2);
        tokens[2][0] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;
        tokens[2][1] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;

        tokens[3] = new address[](3);
        tokens[3][0] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;
        tokens[3][1] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        tokens[3][2] = 0x1789e0043623282D5DCc7F213d703C6D8BAfBB04;

        bytes memory tradeData = hex"84a7f3dd05010001fb66e944021bf915cfb4dac2b20653930bf7d35a062d8dd054ece800011789e0043623282d5dcc7f213d703c6d8bafbb0408bfebb362e0d77e2e00010b629fe58d1b8702c1cdb75d93a7851b7591778c0001e5d7c2a44ffddf6b295a15c148167daaaf5cf34f061aa191cf76a500000001e4eeb461ad1e4ef8b8ef71a33694ccd84af051c4058e00f0cc72000000015fbdf89403270a1846f5ae7d113a989f850d1566062fd42043e6d400000001aca92e438df0b2401ff60da7e4337b687a2435da03013f5200000001176211869ca2b568f2a7d4ee941e073a821ee1ff0405f6cd2100017a841521878f484438f40691d91d8fccea4e8577000000000902060b060805010102000305010003040032040a0501050600080a0501070800020d0501090a00ff0000000000000000000000000000000000000000000000002a4769bea90d379c96cdff7addee77b87016166e5fbdf89403270a1846f5ae7d113a989f850d15660b629fe58d1b8702c1cdb75d93a7851b7591778c1789e0043623282d5dcc7f213d703c6d8bafbb04b0091b7e234a67182712925ee4ef48c11bce6159e4eeb461ad1e4ef8b8ef71a33694ccd84af051c409666eaf650dc52cece84b1bcd2dd78997d239c7aca92e438df0b2401ff60da7e4337b687a2435dae1d9617c4dd72589733dd1d418854804d5c14437e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000000000000000000000000000";

        uint256[2] memory allocations = [uint256(556336), uint256(0)];

        // Record balances before the claim
        uint256 userUsdcBalanceBefore = usdc.balanceOf(userAccount);
        uint256 userRexBalanceBefore = aero.balanceOf(userAccount);

        console.log("User USDC balance before claim:", userUsdcBalanceBefore);
        console.log("User REX balance before claim:", userRexBalanceBefore);

        // Call xRexClaim with the specific data
        vm.startPrank(0xf161e7c79e0c0A3FD8D75A05A53A04E05B2034d3);
        uint256 result = XRexFacet(userAccount).xRexClaim(
            productionLoan,
            fees,
            tokens,
            tradeData,
            allocations
        );
        vm.stopPrank();

        // Record balances after the claim
        uint256 userUsdcBalanceAfter = usdc.balanceOf(userAccount);
        uint256 userRexBalanceAfter = aero.balanceOf(userAccount);

        // loan balance should have changed

        console.log("balance", balance);
        (uint256 afterBalance,) =  IXLoan(productionLoan).getLoanDetails(userAccount);
        console.log("afterBalance", afterBalance);
        assertTrue(afterBalance > balance, "Loan balance should have increased");

        // Verify that the claim was successful
        assertTrue(result > 0, "Claim should return a positive result");
        // ensure user acocunt doesnt have USDC
        assertEq(usdc.balanceOf(userAccount), userUsdcBalanceBefore, "User account should have same amount of USDC");
     
    }

    /**
     * @dev Test multicall functionality with XRexFacet operations
     * This test demonstrates batching multiple operations in a single transaction
     */
    function testMulticallOperations() public {
        uint256 amount = 1e6;
        uint256 increaseAmount = 5e5; // 0.5e6
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingRexBalance = aero.balanceOf(address(user));

        // Prepare multicall data for multiple operations
        bytes[] memory calls = new bytes[](4);
        
        // 1. Request loan
        calls[0] = abi.encodeWithSelector(
            XRexFacet.xRexRequestLoan.selector,
            IERC20(aero).balanceOf(user),
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );

        // 2. Increase loan
        calls[1] = abi.encodeWithSelector(
            XRexFacet.xRexIncreaseLoan.selector,
            address(loan),
            increaseAmount
        );

        // 3. Set up voting data
        address[] memory pools = new address[](1);
        pools[0] = address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100e18; // 100% weight

        // 3. User vote
        calls[2] = abi.encodeWithSelector(
            XRexFacet.xRexUserVote.selector,
            address(loan),
            pools,
            weights
        );

        // 4. Vote (automatic voting)
        calls[3] = abi.encodeWithSelector(
            XRexFacet.xRexVote.selector,
            address(loan)
        );

        // Execute multicall
        vm.startPrank(user);
        bytes[] memory results = FortyAcresPortfolioAccount(payable(userAccount)).multicall(calls);
        vm.stopPrank();

        // Verify all operations were successful
        assertEq(results.length, 4, "Should have 4 results");
        
        // Verify loan was created and increased
        (uint256 balance, address borrower) = loan.getLoanDetails(userAccount);
        assertTrue(balance >= amount + increaseAmount, "Loan balance should be at least the requested amount plus increase");
        assertEq(borrower, address(userAccount), "Borrower should be the user account");

        // Verify user received the loan funds
        uint256 endingUserBalance = usdc.balanceOf(address(user));
        assertTrue(endingUserBalance > startingUserBalance, "User should have received loan funds");
        assertEq(endingUserBalance, startingUserBalance + amount + increaseAmount, "User should have received exact loan amounts");

        // Verify active assets in loan contract
        assertEq(loan.activeAssets(), amount + increaseAmount, "Active assets should match loan amount");

        console.log("Multicall test completed successfully");
        console.log("Final loan balance:", balance);
        console.log("User USDC balance:", endingUserBalance);
    }

    function testMulticallFailure() public  {
        // First set up a loan
        vm.startPrank(user);
        XRexFacet(userAccount).xRexRequestLoan(
            IERC20(aero).balanceOf(user),
            address(loan),
            1e6,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        // Prepare multicall data for claim operations
        bytes[] memory calls = new bytes[](3);
        
        // 1. Vote first
        calls[0] = abi.encodeWithSelector(
            XRexFacet.xRexVote.selector,
            address(loan)
        );

        // 2. Set up voting for rewards
        address[] memory pools = new address[](1);
        pools[0] = address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100e18;

        calls[1] = abi.encodeWithSelector(
            XRexFacet.xRexUserVote.selector,
            address(loan),
            pools,
            weights
        );

        // 3. Increase collateral (simulate claiming rewards and adding collateral)
        calls[2] = abi.encodeWithSelector(
            XRexFacet.xRexIncreaseCollateral.selector,
            address(loan),
            1000000000e18 // large amount to fail
        );

        // Record initial state
        (uint256 initialLoanBalance, ) = loan.getLoanDetails(userAccount);
        uint256 initialRexBalance = aero.balanceOf(userAccount);

        // Execute multicall
        vm.startPrank(user);
        vm.expectRevert();
        bytes[] memory results = FortyAcresPortfolioAccount(payable(userAccount)).multicall(calls);
        vm.stopPrank();
    }
}
