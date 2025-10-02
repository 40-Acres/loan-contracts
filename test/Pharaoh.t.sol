// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {PharaohLoanV2} from "../src/Pharaoh/PharaohLoanV2.sol";
import {PharaohFacet} from "../src/facets/account/PharaohFacet.sol";
import {ILoan} from "../src/interfaces/ILoan.sol";
import { Loan as Loanv2 } from "../src/LoanV2.sol";
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
import {PharaohDeploy} from "../script/PharaohDeploy.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {PharaohSwapper as Swapper} from "../src/Pharaoh/PharaohSwapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";

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
 * @title PharaohTest
 * @dev Test contract for Pharaoh Loan facet functionality with portfolio accounts
 */
contract PharaohTest is Test {
    uint256 fork;
    uint256 fork2;
    uint256 _fork = vm.createFork(vm.envString("AVAX_RPC_URL"));

    IERC20 aero = IERC20(0xAAAB9D12A30504559b0C5a9A5977fEE4A6081c6b);
    IUSDC usdc = IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IVotingEscrow votingEscrow =
        IVotingEscrow(0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);
    IERC20 weth = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IVoter public voter = IVoter(0xAAAf3D9CDD3602d117c67D80eEC37a160C8d9869);
    address[] pool = [address(0x1a2950978E29C5e590C77B0b6247beDbFB0b4185)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    PharaohLoanV2 public loan;
    PharaohFacet public loanFacet;
    address owner;
    address user;
    uint256 tokenId = 3801;

    uint256 expectedRewards = 1269895;

    Swapper public swapper;

    // Account Factory system
    PortfolioFactory public portfolioFactory;

    function setUp() public {
        fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        fork2 = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork2);
        vm.rollFork(62047585);
        vm.selectFork(_fork);
        vm.rollFork(64204517);
        vm.selectFork(fork);
        vm.rollFork(62112514);
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        console.log("user", user);
        PharaohDeploy deployer = new PharaohDeploy();
        (loan, vault, swapper) = deployer.deploy();

        // Deploy Account Factory system
        _deployPortfolioFactory();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        loan.setSwapper(address(swapper));
        loan.setPortfolioFactory(address(portfolioFactory));
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Approve the pool for voting
        address[] memory pools = new address[](1);
        pools[0] = address(0x1a2950978E29C5e590C77B0b6247beDbFB0b4185);
        loan.setApprovedPools(pools, true);
        vm.stopPrank();

        // Deploy the PharaohFacet
        loanFacet = new PharaohFacet(address(portfolioFactory));

        // Register PharaohFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](6);
        loanSelectors[0] = 0xd190b90b; // pharaohRequestLoan(address,uint256,uint256,uint8,uint256,address,bool,bool)
        loanSelectors[1] = 0x777945a8; // pharaohIncreaseLoan(address,uint256,uint256)
        loanSelectors[2] = 0x5780b3ee; // pharaohClaimCollateral(address,uint256)
        loanSelectors[3] = 0xfbb66d95; // pharaohVote(address,uint256)
        loanSelectors[4] = 0xe8b820ba; // pharaohUserVote(address,uint256[],address[],uint256[])
        loanSelectors[5] = 0xd69af01c; // pharaohClaim(address,uint256,address[],address[][],bytes,uint256[2])

        // Get the FacetRegistry from the PortfolioFactory
        FacetRegistry facetRegistry = FacetRegistry(
            portfolioFactory.facetRegistry()
        );
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "PharaohFacet"
        );

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        vm.prank(address(user));
        voter.reset(tokenId);
        vm.stopPrank();
        vm.prank(votingEscrow.ownerOf(3687));
        voter.reset(3687);
        vm.stopPrank();
    }

    function _deployPortfolioFactory() internal {
        // Deploy FacetRegistry
        FacetRegistry facetRegistry = new FacetRegistry();

        // Deploy PortfolioFactory
        portfolioFactory = new PortfolioFactory(
            address(facetRegistry)
        );
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testNftOwner() public view {
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    /**
     * @dev Test the getMaxLoan functionality through the PharaohFacet
     */
    function testGetMaxLoan() public {
        // Test initial max loan through the facet
        (uint256 maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 80e6);

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

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        // log users _asset balance
        uint256 userAssetBalance = IERC20(loan._asset()).balanceOf(user);
        vm.startPrank(user);
        uint256 amount = 5e6;
        PharaohFacet(userAccount).pharaohRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );

        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + amount
        );

        // the tokenId should be owned by the user account after requesting a loan
        assertEq(votingEscrow.ownerOf(tokenId), address(userAccount));

        // Test max loan after requesting a loan through the facet
        (maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 75e6);

        // Test max loan after increasing loan through the direct contract
        PharaohFacet(userAccount).pharaohIncreaseLoan(address(loan), tokenId, 70e6);
        (maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6
        );

        // Test max loan after maxing out the loan through the direct contract
        PharaohFacet(userAccount).pharaohIncreaseLoan(address(loan), tokenId, 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6 + 5e6
        );
        (maxLoan, ) = loan.getMaxLoan(tokenId);
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
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);
            vm.stopPrank();
            vm.startPrank(user);
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        vm.startPrank(user);
        uint256 amount = 1e6;
        PharaohFacet(userAccount).pharaohRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.roll(block.number + 1);
        loan.vote(tokenId);
        vm.stopPrank();

        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertEq(loan.activeAssets(), 1e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, address(userAccount));

        // owner of token should be the user account (portfolio account)
        assertEq(votingEscrow.ownerOf(tokenId), address(userAccount));
    }

    /**
     * @dev Test loan increase through the facet
     */
    function testIncreaseLoan() public {
        uint256 amount = 1e6;
        uint256 startingUserBalance = usdc.balanceOf(address(user));

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);
            vm.stopPrank();
            vm.startPrank(user);
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        vm.startPrank(user);
        PharaohFacet(userAccount).pharaohRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3601);
        vm.warp(block.timestamp+1);
        loan.vote(tokenId);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6, "User should have more than loan");

        assertEq(loan.activeAssets(),1e6, "ff");
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be 1e6");
        assertEq(borrower, address(userAccount));

        vm.startPrank(user);
        PharaohFacet(userAccount).pharaohIncreaseLoan(address(loan), tokenId, amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance> amount, "Balance should be more than amount");
        assertEq(borrower, address(userAccount));
        assertEq(loan.activeAssets(),2e6, "ff");

        assertEq(usdc.balanceOf(address(user)), 2e6 + startingUserBalance, "User should have .02e6");
        assertEq(usdc.balanceOf(address(vault)), 98e6, "Loan should have 1e6");
    }

    /**
     * @dev Test loan payoff through the facet
     */
    function testLoanFullPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);
        vm.stopPrank();

        uint256 amount = 1e6;
        assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0xa20c959b19F114e9C2D81547734CdC1110bd773D);

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
        loan.userVote(tokenIds, manualPools, manualWeights);

        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), 1e6+startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Loan should have 97e6");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        vm.expectRevert();
        loan.reset(tokenId); // should not be able to reset loan with balance
        loan.pay(tokenId, 0);
        loan.reset(tokenId);
        loan.claimCollateral(tokenId);
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    function testUpgradeLoan() public {
        vm.startPrank(loan.owner());
        PharaohLoanV2 loanV2 = new PharaohLoanV2();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();
    }

    function testMerge() public {
        uint256 _tokenId = 3687;
        address _user = votingEscrow.ownerOf(tokenId);
        vm.startPrank(_user);        
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), true, false);
        vm.stopPrank();
        
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        
        address _user2 = votingEscrow.ownerOf(_tokenId);
        vm.prank(_user2);
        votingEscrow.transferFrom(_user2, address(_user), _tokenId);

      
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        vm.startPrank(_user);
        voter.reset(_tokenId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        

        require(votingEscrow.isApprovedOrOwner(address(loan), _tokenId), "should be approved");
        require(votingEscrow.isApprovedOrOwner(address(loan), tokenId), "should be approved");
        require(votingEscrow.isApprovedOrOwner(address(_user), _tokenId), "should be approved");


        loan.merge(_tokenId, tokenId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertEq(votingEscrow.ownerOf(_tokenId), address(0), "should be burnt");
    }

    function testManualVoting() public {
        uint256 _tokenId = 3687;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);

        
        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0xa20c959b19F114e9C2D81547734CdC1110bd773D);
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
        vm.warp(block.timestamp + 3601);
        loan.vote(_tokenId);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        vm.startPrank(_user);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;
        loan.userVote(tokenIds, manualPools, manualWeights);
    }

    function _claimRewards(
        PharaohLoanV2 _loan,
        uint256 _tokenId,
        address[] memory bribes,
        bytes memory tradeData,
        uint256[2] memory allocations
    ) internal returns (uint256) {
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
        uint256 result = PharaohFacet(address(_loan)).pharaohClaim(
            address(loan), // Use the actual loan contract address
            _tokenId,
            fees,
            tokens,
            tradeData,
            allocations
        );
        vm.stopPrank();
        return result;
    }
}