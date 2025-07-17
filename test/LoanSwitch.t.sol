// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {LoanV2Native} from "../src/LoanV2Native.sol";
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
import {NativeVaultDeploy} from "../script/NativeVaultDeploy.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

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

contract LoanSwitchTest is Test {
    uint256 fork;

    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault usdcVault;
    Vault aeroVault;
    Loan public usdcLoan;
    Loan public tempLoan;
    LoanV2Native public aeroLoan;
    address owner;
    address user;
    uint256 tokenId = 64196;

    Swapper public swapper;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24353746);
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        
        // Deploy USDC loan contracts
        BaseDeploy usdcDeployer = new BaseDeploy();
        (usdcLoan, usdcVault) = usdcDeployer.deployLoan();
        
        // Deploy AERO loan contracts
        // For simplicity, we'll reuse the BaseDeploy but override the vault asset later
        NativeVaultDeploy aeroDeployer = new NativeVaultDeploy();
        (tempLoan, aeroVault) = aeroDeployer.deployNative(address(tempLoan), address(aero), "40base-AERO-VAULT", "40base-AERO-VAULT");

        vm.stopPrank();
        
        // Cast to LoanV2Native
        aeroLoan = LoanV2Native(address(tempLoan));

        // Configure both loan contracts
        vm.startPrank(address(usdcDeployer));
        usdcLoan.setMultiplier(100000000000);
        usdcLoan.setRewardsRate(11300);
        usdcLoan.setLenderPremium(2000);
        usdcLoan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(usdcLoan)).transferOwnership(owner);
        
        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        usdcLoan.setSwapper(address(swapper));
        vm.stopPrank();
        
        vm.startPrank(address(aeroDeployer));
        aeroLoan.setMultiplier(100000000000);
        aeroLoan.setRewardsRate(400);
        aeroLoan.setLenderPremium(2000);
        aeroLoan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(aeroLoan)).transferOwnership(owner);
        aeroLoan.setSwapper(address(swapper));
        vm.stopPrank();

        // Accept ownership on both contracts
        vm.startPrank(owner);
        IOwnable(address(usdcLoan)).acceptOwnership();
        IOwnable(address(aeroLoan)).acceptOwnership();
        
        // Set up contract approvals for switching
        usdcLoan.setApprovedContract(address(aeroLoan), true);
        aeroLoan.setApprovedContract(address(usdcLoan), true);
        
        // Configure contract assets
        usdcLoan.setContractAsset(address(usdcLoan), address(usdc));
        usdcLoan.setContractAsset(address(aeroLoan), address(aero));
        aeroLoan.setContractAsset(address(usdcLoan), address(usdc));
        aeroLoan.setContractAsset(address(aeroLoan), address(aero));
        vm.stopPrank();

        // allow this test contract to mint USDC and AERO
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(usdcVault), 100e6);
        
        // Mint some AERO to the AERO vault
        vm.prank(0x40EbC1Ac8d4Fedd2E144b75fe9C0420BE82750c6); // AERO whale
        aero.transfer(address(aeroVault), 100 ether);
    }

    function testSwitchWithoutLoan() public {
        // Set up the initial loan in USDC
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(usdcLoan), tokenId);
        
        // Request a loan with 0 amount - just lock the collateral
        usdcLoan.requestLoan(
            tokenId, 
            0, 
            Loan.ZeroBalanceOption.DoNothing, 
            5000, // 50% increase percentage
            address(0), 
            false, 
            false
        );
        
        // Verify the NFT is locked in the USDC contract
        assertEq(votingEscrow.ownerOf(tokenId), address(usdcLoan));
        
        // Now switch to AERO contract
        usdcLoan.transferWithin40Acres(
            address(aeroLoan),
            tokenId,
            0 ether, // Borrow 1 AERO in the new contract
            "" // No swap needed since we don't have an outstanding loan
        );
        
        // Verify the NFT is now locked in the AERO contract
        assertEq(votingEscrow.ownerOf(tokenId), address(aeroLoan));
        
        // Verify settings were transferred
        (uint256 balance, address borrower) = aeroLoan.getLoanDetails(tokenId);
        assertEq(borrower, user);
        assertEq(balance, 0); // 1 AERO + 0.8% fee
        
        // Test that we can claim the collateral from the AERO contract
        aeroLoan.pay(tokenId, balance);
        aeroLoan.claimCollateral(tokenId);
        
        // Verify the NFT is back with the user
        assertEq(votingEscrow.ownerOf(tokenId), user);
        vm.stopPrank();
    }

    /**
     * @notice Helper function to mint AERO tokens in tests
     * @dev This is called by the MockOdosRouter to mint AERO tokens as part of a swap
     * @param from The address to prank as the source of tokens
     * @param to The recipient of the tokens
     * @param amount The amount of tokens to mint
     */
    function mintAero(address from, address to, uint256 amount) external {
        // No restriction on caller in tests
        vm.startPrank(from);
        aero.transfer(to, amount);
        vm.stopPrank();
    }
    
    /**
     * @notice Helper function to mint USDC tokens in tests
     * @dev This is called by the MockOdosRouter to mint USDC tokens as part of a swap
     * @param minter The address with minting permission
     * @param to The recipient of the tokens
     * @param amount The amount of tokens to mint
     */
    function mintUsdc(address minter, address to, uint256 amount) external {
        // No restriction on caller in tests
        vm.startPrank(minter);
        IUSDC(address(usdc)).mint(to, amount);
        vm.stopPrank();
    }
    
    function testSwitchWithLoan() public {
        // Add mock implementation of ODOS router for testing
        address mockOdosRouter = deployMockOdosRouter();
        
        // Set up the initial loan in USDC
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(usdcLoan), tokenId);
        
        // Request a loan with 10 USDC
        usdcLoan.requestLoan(
            tokenId, 
            10e6, // 10 USDC
            Loan.ZeroBalanceOption.DoNothing, 
            5000, // 50% increase percentage
            address(0), 
            false, 
            false
        );
        
        // Verify the NFT is locked in the USDC contract
        assertEq(votingEscrow.ownerOf(tokenId), address(usdcLoan));
        
        // Verify loan balance
        (uint256 usdcBalance, address borrower) = usdcLoan.getLoanDetails(tokenId);
        assertEq(borrower, user);
        assertEq(usdcBalance, 10.08e6); // 10 USDC + 0.8% fee
        
        // Create mock trade data for the ODOS router
        bytes memory mockTradeData = abi.encodePacked(uint256(1), uint256(2), uint256(3));
        
        // Prepare approvals for AERO to be spent
        aero.approve(address(aeroLoan), 100 ether);
        
        // Now switch to AERO contract
        usdcLoan.transferWithin40Acres(
            address(aeroLoan),
            tokenId,
            0.001 ether, // Borrow 0.0015 AERO in the new contract
            mockTradeData // Mock trade data
        );
        
        // Verify the NFT is now locked in the AERO contract
        assertEq(votingEscrow.ownerOf(tokenId), address(aeroLoan));
        
        // Verify loan in AERO contract
        (uint256 aeroBalance, address aeroBorrower) = aeroLoan.getLoanDetails(tokenId);
        assertEq(aeroBorrower, user);
        assertEq(aeroBalance, 0.001008 ether); // 0.001 AERO + 0.8% fee
        
        // Verify the USDC loan has been paid off
        (uint256 usdcBalanceAfter, ) = usdcLoan.getLoanDetails(tokenId);
        assertEq(usdcBalanceAfter, 0); // Loan should be paid off
        
        // Test that we can claim the collateral from the AERO contract
        aeroLoan.pay(tokenId, aeroBalance);
        aeroLoan.claimCollateral(tokenId);
        
        // Verify the NFT is back with the user
        assertEq(votingEscrow.ownerOf(tokenId), user);
        vm.stopPrank();
    }
    
    // Helper to deploy a mock ODOS router that actually performs swaps
    function deployMockOdosRouter() internal returns (address) {
        // Deploy the MockOdosRouter contract
        MockOdosRouter mockRouter = new MockOdosRouter();
        
        // Configure the router with token addresses and test environment
        mockRouter.setup(address(usdc), address(aero), address(this));
        
        // Mock the ODOS router address in the loan contracts
        vm.mockCall(
            address(usdcLoan),
            abi.encodeWithSignature("odosRouter()"),
            abi.encode(address(mockRouter))
        );
        
        vm.mockCall(
            address(aeroLoan),
            abi.encodeWithSignature("odosRouter()"),
            abi.encode(address(mockRouter))
        );
        
        return address(mockRouter);
    }
}

// Mock ODOS Router contract that simulates swaps
contract MockOdosRouter {
    IERC20 public usdcToken;
    IERC20 public aeroToken;
    address public testContract;
    uint256 public constant SWAP_RATE = 10; // 1 AERO = 10 USDC (price ratio)
    
    function setup(address _usdcToken, address _aeroToken, address _testContract) external {
        usdcToken = IERC20(_usdcToken);
        aeroToken = IERC20(_aeroToken);
        testContract = _testContract;
    }
    
    // Function to handle incoming calls (fallback)
    fallback() external {
        // Process the swap based on approvals and balances
        processSwap();
    }
    
    // Handle specific call for router to maintain compatibility
    receive() external payable {
        processSwap();
    }
    
    function processSwap() internal {
        // Check which token has been approved to this contract
        uint256 usdcAllowance = usdcToken.allowance(msg.sender, address(this));
        uint256 aeroAllowance = aeroToken.allowance(msg.sender, address(this));
        
        if (usdcAllowance > 0) {
            // USDC to AERO swap
            uint256 usdcAmount = usdcAllowance;
            
            // Transfer USDC from sender to this contract
            usdcToken.transferFrom(msg.sender, address(this), usdcAmount);
            
            // Calculate AERO amount (1 USDC = 0.1 AERO)
            uint256 aeroAmount = usdcAmount / SWAP_RATE;
            
            // Mint AERO to the sender
            address aeroWhale = 0x40EbC1Ac8d4Fedd2E144b75fe9C0420BE82750c6;
            
            // Call the test contract to mint tokens
            (bool success,) = testContract.call(
                abi.encodeWithSignature(
                    "mintAero(address,address,uint256)",
                    aeroWhale, msg.sender, aeroAmount
                )
            );
        } 
        else if (aeroAllowance > 0) {
            // AERO to USDC swap
            uint256 aeroAmount = aeroAllowance;
            
            // Transfer AERO from sender to this contract
            aeroToken.transferFrom(msg.sender, address(this), aeroAmount);
            
            // Calculate USDC amount (1 AERO = 10 USDC)
            uint256 usdcAmount = aeroAmount * SWAP_RATE;
            
            // Mint USDC to the sender
            address usdcMinter = IUSDC(address(usdcToken)).masterMinter();
            
            // Call the test contract to mint tokens
            (bool success,) = testContract.call(
                abi.encodeWithSignature(
                    "mintUsdc(address,address,uint256)",
                    usdcMinter, msg.sender, usdcAmount
                )
            );
        }
    }
}