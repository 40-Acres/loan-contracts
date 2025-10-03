// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {PharaohLoanV2} from "../src/Pharaoh/PharaohLoanV2.sol";
import {XPharaohFacet} from "../src/facets/account/XPharaohFacet.sol";
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
import {XPharaohLoan} from "../src/Pharaoh/XPharaohLoan.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";

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
contract XPharaohTest is Test {
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
    Vault vault = Vault(0x5050451000218372014124115410386622976525);
    PharaohLoanV2 public loan = PharaohLoanV2(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F);
    XPharaohFacet public loanFacet;
    address owner;
    address user;
    uint256 tokenId = 6734;

    uint256 expectedRewards = 1269895;

    Swapper public swapper;
    address loanContract = 0xf6A044c3b2a3373eF2909E2474f3229f23279B5F;

    // Account Factory system
    PortfolioFactory public portfolioFactory;

    function setUp() public {
        fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(69671206);
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);

        // Deploy Account Factory system
        _deployPortfolioFactory();
        address deployer = IOwnable(address(loan)).owner();
        vm.startPrank(address(deployer));
        PharaohLoanV2 loanImpl = new PharaohLoanV2();
        Loanv2(address(loan)).upgradeToAndCall(address(loanImpl), new bytes(0));
        IOwnable(address(loan)).transferOwnership(owner);
        loan.setPortfolioFactory(address(portfolioFactory));
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Approve the pool for voting
        address[] memory pools = new address[](1);
        pools[0] = address(0x1a2950978E29C5e590C77B0b6247beDbFB0b4185);
        loan.setApprovedPools(pools, true);
        vm.stopPrank();

        // Deploy the XPharaohFacet
        AccountConfigStorage _accountConfigStorage = new AccountConfigStorage();
        ERC1967Proxy accountConfigStorageProxy = new ERC1967Proxy(address(_accountConfigStorage), "");
        AccountConfigStorage accountConfigStorage = AccountConfigStorage(address(accountConfigStorageProxy));
        loanFacet = new XPharaohFacet(address(portfolioFactory), address(accountConfigStorage));
        
        // Set up account configuration to approve the loan contract
        vm.prank(IOwnable(address(accountConfigStorage)).owner());
        accountConfigStorage.setApprovedContract(address(loan), true);

        // Register XPharaohFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](7);
        loanSelectors[0] = 0xd190b90b; // pharaohRequestLoan(address,uint256,uint256,uint8,uint256,address,bool,bool)
        loanSelectors[1] = 0x777945a8; // pharaohIncreaseLoan(address,uint256,uint256)
        loanSelectors[2] = 0x5780b3ee; // pharaohClaimCollateral(address,uint256)
        loanSelectors[3] = 0xfbb66d95; // pharaohVote(address,uint256)
        loanSelectors[4] = 0xe8b820ba; // pharaohUserVote(address,uint256[],address[],uint256[])
        loanSelectors[5] = 0xd69af01c; // pharaohClaim(address,uint256,address[],address[][],bytes,uint256[2])
        loanSelectors[6] = 0x61622de4; // migratePharaohToXPharaoh(uint256)

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

    function testMigration() public {
        // Deploy XPharaohLoan implementation
        XPharaohLoan xPharaohLoanImpl = new XPharaohLoan();
        
        // Deploy proxy for XPharaohLoan
        bytes memory initData = abi.encodeWithSelector(
            XPharaohLoan.initialize.selector,
            address(vault),
            address(usdc)
        );
        
        ERC1967Proxy xPharaohLoanProxy = new ERC1967Proxy(address(xPharaohLoanImpl), initData);
        XPharaohLoan xPharaohLoan = XPharaohLoan(address(xPharaohLoanProxy));
        
        // Set up the XPharaohLoan with PortfolioFactory
        xPharaohLoan.setPortfolioFactory(address(portfolioFactory));
        
        // Check if the loan has data for this token
        (uint256 balance, address borrower) = PharaohLoanV2(address(loan)).getLoanDetails(tokenId);
        console.log("Token", tokenId, "balance:", balance);
        console.log("Token", tokenId, "borrower:", borrower);
        
        // Only proceed if there's loan data
        if (borrower != address(0)) {
            // Call migrateNft on PharaohLoanV2, which will call XPharaohLoan
            vm.startPrank(owner); // Use the owner of the loan contract
            PharaohLoanV2(address(loan)).migrateNft(tokenId, address(xPharaohLoan));
            vm.stopPrank();
        } else {
            console.log("No loan data found for token", tokenId);
        }
    }
}