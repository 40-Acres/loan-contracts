// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {EtherexLoanV2} from "../src/Etherex/EtherexLoanV2.sol";
import {XRexFacet} from "../src/facets/account/XRexFacet.sol";
import {IXLoan} from "../src/interfaces/IXLoan.sol";
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
import {EtherexDeploy} from "../script/EtherexDeploy.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {CollateralStorage} from "../src/storage/CollateralStorage.sol";

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
    IVoter public voter = IVoter(0x942117Ec0458a8AA08669E94B52001Bd43F889C1);
    address[] pool = [address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    EtherexLoanV2 public loan;
    XRexFacet public loanFacet;
    address owner;
    address user;
    uint256 amount = 14054997634637524683;
    uint256 tokenId = amount;

    uint256 expectedRewards = 957174473;

    Swapper public swapper;

    // Account Factory system
    PortfolioFactory public portfolioFactory;
    CollateralStorage public collateralStorage;

    function setUp() public {
        fork = vm.createFork(vm.envString("LINEA_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(23961806);
        owner = vm.addr(0x123);
        user = 0x97BE22DBb49C88451fBd1099F59EED963d9d8A12;
        EtherexDeploy deployer = new EtherexDeploy();
        (EtherexLoanV2 loanV2, Vault deployedVault, Swapper deployedSwapper) = deployer.deploy();
        loan = EtherexLoanV2(address(loanV2));
        vault = deployedVault;
        swapper = deployedSwapper;

        // Deploy Account Factory system
        _deployPortfolioFactory();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        loan.setAccountStorage(address(portfolioFactory));
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Approve the pool for voting
        address[] memory pools = new address[](1);
        pools[0] = address(0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e);
        loan.setApprovedPools(pools, true);
        vm.stopPrank();

        // Deploy the XRexFacet
        loanFacet = new XRexFacet(address(portfolioFactory), address(collateralStorage));

        // Register XRexFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](7);
        loanSelectors[0] = 0x6b298621; // xRexRequestLoan(address,uint256,uint8,uint256,address,bool)
        loanSelectors[1] = 0x86e057a2; // xRexIncreaseLoan(address,uint256)
        loanSelectors[2] = 0x1fa1642f; // xRexClaimCollateral(address)
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
    }

    function _deployPortfolioFactory() internal {
        // Deploy FacetRegistry
        FacetRegistry facetRegistry = new FacetRegistry();

        // Deploy PortfolioFactory
        portfolioFactory = new PortfolioFactory(
            address(facetRegistry)
        );

        // Deploy CollateralStorage
        collateralStorage = new CollateralStorage(address(portfolioFactory));

        // Note: We'll authorize user accounts as they're created
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testNftOwner() public view {
        assertEq(votingEscrow.balanceOf(address(user)), amount);
    }

    /**
     * @dev Test the getMaxLoan functionality through the XRexFacet
     * This replicates the testGetMaxLoan test from LoanTest but uses the XRexFacet
     */
    function testGetMaxLoan() public {
        // Test initial max loan through the facet
        (uint256 maxLoan, ) = loan.getMaxLoan(user);
        assertEq(maxLoan, 0);

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

        // log users _asset balance
        uint256 userAssetBalance = IERC20(loan._asset()).balanceOf(user);
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
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + amount
        );

        // the tokenId should be owned by the user account after requesting a loan
        assertEq(votingEscrow.balanceOf(address(userAccount)), amount);

        // Test max loan after requesting a loan through the facet
        (maxLoan, ) = loan.getMaxLoan(user);
        assertEq(maxLoan, 75e6);

        // Test max loan after increasing loan through the direct contract
        XRexFacet(userAccount).xRexIncreaseLoan(address(loan), 70e6);
        (maxLoan, ) = loan.getMaxLoan(user);
        assertEq(maxLoan, 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6
        );

        // Test max loan after maxing out the loan through the direct contract
        XRexFacet(userAccount).xRexIncreaseLoan(address(loan), 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
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

        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        // Verify the loan details through the facet
        (uint256 balance, address borrower) = loan.getLoanDetails(user);
        assertTrue(balance > amount);
        assertEq(borrower, address(userAccount));

        // Verify the NFT ownership - should be owned by user account after requesting loan
        assertEq(votingEscrow.balanceOf(address(userAccount)), amount);
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

        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertEq(loan.activeAssets(), 1e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(user);
        assertTrue(balance > amount);
        assertEq(borrower, address(userAccount));

        // Test increasing the loan through the facet
        vm.startPrank(user);
        XRexFacet(userAccount).xRexIncreaseLoan(address(loan), amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(user);
        assertTrue(balance > amount);
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
        vm.stopPrank();
        bool voteResult = XRexFacet(userAccount).xRexVote(address(loan));

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
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
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
        assertEq(votingEscrow.balanceOf(address(user)), amount);

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
        XRexFacet(userAccount).xRexRequestLoan(
            address(loan),
            amount,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(user)), 1e6 + startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 99e6);
        assertEq(votingEscrow.balanceOf(address(userAccount)), amount);

        // Test payoff through the facet
        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        loan.pay(user, 0);

        assertEq(votingEscrow.balanceOf(address(userAccount)), amount);

        XRexFacet(userAccount).xRexClaimCollateral(address(loan));

        assertEq(votingEscrow.balanceOf(address(user)), amount);
        vm.stopPrank();
    }

    function testClaim() public {
        uint256 amount = 1e6;
        uint256 startingUserBalance = usdc.balanceOf(address(user));

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            userAccount = portfolioFactory.createAccount(user);
        }

        // Transfer NFT to user account
        votingEscrow.transferFrom(user, userAccount, tokenId);
        vm.stopPrank();

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
        (uint256 balance, ) = loan.getLoanDetails(user);
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
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100000000000000000000; // 100 tokens

        // This should work through the user account
        XRexFacet(userAccount).xRexUserVote(
            address(loan),
            pools,
            weights
        );
        vm.stopPrank();

        // Verify the vote was recorded
        address votedPool = voter.poolVote(tokenId, 0);
        assertEq(votedPool, pools[0], "Pool should be voted for");

        console.log("User account integration test passed");
        console.log("Loan balance:", balance);
        console.log(
            "User USDC balance change:",
            endingUserBalance - startingUserBalance
        );

        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        bytes
            memory data = hex"84a7f3dd020100016877B1b0c6267E0AD9aa4C0df18A547AA2f6B08d073a9f858ec468c400020704077c61afebec0001df033790907c60c9B81aE355F76F74f52F92114A00016e2c81b6c2c0e02360f00a0da694e489acb0b05e090764453ee13b356a3700000004043b927079000187f18b377e625b62c708D5f6EA96EC193558EFD0000000000401030500340201000102018000001702080201030401ff000000000000000000df033790907c60c9b81ae355f76f74f52f92114a420000000000000000000000000000000000000651c230951b82dbf7b8696b6fcd2be199cc10779f6e2c81b6c2c0e02360f00a0da694e489acb0b05e00000000000000000000000000000000";
        uint256[2] memory allocations = [
            uint256(41349),
            uint256(21919478169541)
        ];
        uint256 rewards = _claimRewards(
            Loan(userAccount),
            bribes,
            data,
            allocations
        );
        uint256 endingUserUsdcBalance = usdc.balanceOf(address(user));
        assertTrue(
            endingUserUsdcBalance > beginningUserUsdcBalance,
            "User should have received rewards"
        );
    }

    function _claimRewards(
        Loan _loan,
        address[] memory bribes,
        bytes memory tradeData,
        uint256[2] memory allocations
    ) internal returns (uint256) {
        address[] memory pools = new address[](256); // Assuming a maximum of 256 pool votes
        uint256 index = 0;

        // while (true) {
        //     try voter.poolVote(_tokenId, index) returns (address _pool) {
        //         pools[index] = _pool;
        //         index++;
        //     } catch {
        //         break; // Exit the loop when it reverts
        //     }
        // }

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
