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
import {EtherexDeploy} from "../script/EtherexDeploy.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";


contract MockOdosRouterRL {
    address public testContract;

    address ODOS = 0x2d8879046f1559E53eb052E949e9544bCB72f414;
    address USDC = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
    address REX = 0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348;
    
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external returns (bool) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(tokenOut).masterMinter(), msg.sender, amountOut));
        require(success, "mint fail");
        return true;
    }


    function executeSwapMultiOutput(uint256 amount1, uint256 amount2) external returns (bool) {
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(0x176211869cA2b568f2A7D4EE941E073a821EE1ff).masterMinter(), msg.sender, amount1));
        require(success, "mint fail");

        (bool success2,) = testContract.call(abi.encodeWithSignature("mintRex(address,uint256)", msg.sender, amount2));
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

    IERC20 aero = IERC20(0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348);
    IUSDC usdc = IUSDC(0x176211869cA2b568f2A7D4EE941E073a821EE1ff);
    IERC20 votingEscrow =
        IERC20(0xc93B315971A4f260875103F5DA84cB1E30f366Cc);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IXVoter public voter = IXVoter(0x942117Ec0458a8AA08669E94B52001Bd43F889C1);
    address[] pool = [address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e)];
    ProxyAdmin admin;
    address userAccount;

    address ODOS = 0x2d8879046f1559E53eb052E949e9544bCB72f414;
    address REX = 0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348;
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
        (EtherexLoan loanV2, Vault deployedVault, Swapper deployedSwapper, AccountConfigStorage _accountConfigStorage) = deployer.deploy();
        accountConfigStorage = _accountConfigStorage;
        loan = EtherexLoan(address(loanV2));
        vault = deployedVault;
        swapper = deployedSwapper;
        


        // Send REX token to the user
        vm.prank(0x97a51bAEF69335b6248AFEfEBD95E90399D37b0a);
        aero.transfer(user, 100e6);
        // Deploy Account Factory system
        _deployPortfolioFactory();

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
        pools[0] = address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e);
        loan.setApprovedPools(pools, true);
        vm.stopPrank();

        // Deploy the XRexFacet
        // The test contract is the owner of the simple AccountConfigStorage
        vm.prank(IOwnable(address(accountConfigStorage)).owner());
        accountConfigStorage.setApprovedContract(address(loan), true);
        loanFacet = new XRexFacet(address(portfolioFactory), address(accountConfigStorage));

        // Register XRexFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](7);
        loanSelectors[0] = 0x6b298621; // xRexRequestLoan(address,uint256,uint8,uint256,address,bool)
        loanSelectors[1] = 0x86e057a2; // xRexIncreaseLoan(address,uint256)
        loanSelectors[2] = 0xd56b124c; // xRexClaimCollateral(address,uint256)
        loanSelectors[3] = 0x410f6461; // xRexVote(address)
        loanSelectors[4] = 0x89512b6a; // xRexUserVote(address,address[],uint256[])
        loanSelectors[5] = 0x5f98cbbf; // xRexClaim(address,address[],address[][],bytes,uint256[2])
        loanSelectors[6] = 0xba1e30c1; // claim(uint256,address[],address[][],bytes,uint256[2])

        // Get the FacetRegistry from the PortfolioFactory
        FacetRegistry facetRegistry = FacetRegistry(
            portfolioFactory.facetRegistry()
        );
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "XRexFacet"
        );

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        vm.stopPrank();
        vm.startPrank(user);

        userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            
            vm.startPrank(user); // Resume user prank
        }

      
        IERC20(0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348).approve(address(userAccount), type(uint256).max);
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

    function _deployPortfolioFactory() internal {
        // Deploy FacetRegistry
        FacetRegistry facetRegistry = new FacetRegistry();

        // Deploy PortfolioFactory
        portfolioFactory = new PortfolioFactory(
            address(facetRegistry)
        );

        // Note: We'll authorize user accounts as they're created
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
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

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
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

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
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);
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
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);
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
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

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


        XRexFacet(userAccount).xRexClaimCollateral(address(loan), 2);

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
        address newAccount = portfolioFactory.getAccount(_user);
        assertTrue(portfolioFactory.isUserAccount(newAccount), "New account should be a user account");
        assertEq(portfolioFactory.getAccountOwner(newAccount), _user, "New account owner should be the user");
        assertEq(portfolioFactory.getUserAccount(_user), newAccount, "New account should be the user account");
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
        emit IXVoter.Voted(userAccount, 7027498817418762342, pools[0]);
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
            21919478169540 // send less to account for slippage
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
}
