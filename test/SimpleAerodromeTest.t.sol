// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {LoanFacet} from "../src/facets/account/LoanFacet.sol";
import {ILoan} from "../src/interfaces/ILoan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolTimeLibrary} from "src/libraries/ProtocolTimeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {DeploySwapper} from "../script/BaseDeploySwapper.s.sol";
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
 * @title SimpleAerodromeTest
 * @dev Simplified test for DiamondAccount Loan facet functionality without AssetFacet
 */
contract SimpleAerodromeTest is Test {
    uint256 fork;

    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow =
        IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan;
    LoanFacet public loanFacet;
    address owner;
    address user;
    uint256 tokenId = 64196;

    uint256 expectedRewards = 957174473;

    Swapper public swapper;

    // Account Factory system
    PortfolioFactory public portfolioFactory;
    CollateralStorage public collateralStorage;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24353746);
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();

        // Deploy Account Factory system
        _deployPortfolioFactory();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));
        loan.setAccountStorage(address(portfolioFactory));
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Approve the pool for voting
        address[] memory pools = new address[](1);
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
        loan.setApprovedPools(pools, true);
        vm.stopPrank();

        // Deploy the LoanFacet
        loanFacet = new LoanFacet(address(portfolioFactory), address(collateralStorage));

        // Register LoanFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](7);
        loanSelectors[0] = 0xf4e5753e; // requestLoan(uint256,uint256,uint8,uint256,address,bool,bool)
        loanSelectors[1] = 0x7a792a29; // increaseLoan(uint256,uint256)
        loanSelectors[2] = 0xc49785b4; // claimCollateral(uint256)
        loanSelectors[3] = 0x74630600; // vote(uint256)
        loanSelectors[4] = 0x3bbad66f; // userVote(uint256[],address[],uint256[])
        loanSelectors[5] = 0xba1e30c1; // claim(uint256,address[],address[][],bytes,uint256[2])
        loanSelectors[6] = 0xe5b8778f; // claim(address,uint256,address[],address[][],bytes,uint256[2])

        // Get the FacetRegistry from the PortfolioFactory
        FacetRegistry facetRegistry = FacetRegistry(
            portfolioFactory.facetRegistry()
        );
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "LoanFacet"
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
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    /**
     * @dev Test the getMaxLoan functionality through the LoanFacet
     * This replicates the testGetMaxLoan test from LoanTest but uses the LoanFacet
     */
    function testGetMaxLoan() public {
        // Test initial max loan through the facet
        (uint256 maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 80e6);

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve CollateralStorage to transfer the NFT
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

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
        LoanFacet(userAccount).requestLoan(
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
        LoanFacet(userAccount).increaseLoan(address(loan), tokenId, 70e6);
        (maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6
        );

        // Test max loan after maxing out the loan through the direct contract
        LoanFacet(userAccount).increaseLoan(address(loan), tokenId, 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6 + 5e6
        );
        (maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 0);
        vm.stopPrank();
    }
}
