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
        vm.startPrank(0x40EbC1Ac8d4Fedd2E144b75fe9C0420BE82750c6); // AERO whale
        aero.transfer(address(aeroVault), 100 ether);
        aero.transfer(user, 10 ether);
        vm.stopPrank();

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
            0,
            "" // No swap needed since we don't have an outstanding loan
        );
        
        // Verify the NFT is now locked in the AERO contract
        assertEq(votingEscrow.ownerOf(tokenId), address(aeroLoan));
        
        // Verify settings were transferred
        (uint256 balance, address borrower) = aeroLoan.getLoanDetails(tokenId);
        assertEq(borrower, user);
        assertEq(balance, 0);
        
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
        // vm.startPrank(minter);
        IUSDC(address(usdc)).mint(to, amount);
        // vm.stopPrank();
    }
    
    function testSwitchWithLoan() public {
        // Add mock implementation of ODOS router for testing
        address mockOdosRouter = deployMockOdosRouter();
        
        // Set up the initial loan in USDC
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(usdcLoan), tokenId);

        (uint256 usdcMaxLoan,) = usdcLoan.getMaxLoan(tokenId);
        
        // Request a loan with 10 USDC
        usdcLoan.requestLoan(
            tokenId, 
            usdcMaxLoan, // 10 USDC
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
        assertEq(usdcBalance, usdcMaxLoan * 1008 / 1000); // 10 USDC + 0.8% fee
        
        // Calculate the new AERO loan amount that would cover the USDC loan (with fee)
        (uint256 aeroLoanAmount,) = aeroLoan.getMaxLoan(tokenId); // 0.001 AERO
        uint256 aeroLoanWithFee = aeroLoanAmount * 1008 / 1000; // 0.001 AERO + 0.8% fee = 0.001008 AERO
        
        // Create mock trade data for the ODOS router with the proper function signature
        // Encode the executeSwap function call with parameters
        bytes memory mockTradeData = abi.encodeWithSelector(
            MockOdosRouter.executeSwap.selector,
            address(aero),     // tokenIn
            address(usdc),     // tokenOut
            aeroLoanAmount,       // amountIn (amount of USDC to swap - the entire loan balance)
            usdcBalance     // amountOut (amount of AERO to receive)
        );
        
        // Now switch to AERO contract
        usdcLoan.transferWithin40Acres(
            address(aeroLoan),
            tokenId,
            aeroLoanAmount,
            mockTradeData // Mock trade data
        );
        
        // Verify the NFT is now locked in the AERO contract
        assertEq(votingEscrow.ownerOf(tokenId), address(aeroLoan));
        
        // Verify loan in AERO contract
        (uint256 aeroBalance, address aeroBorrower) = aeroLoan.getLoanDetails(tokenId);
        assertEq(aeroBorrower, user);
        assertEq(aeroBalance, aeroLoanWithFee); // Verify the AERO loan amount with fee
        
        // Verify the USDC loan has been paid off
        (uint256 usdcBalanceAfter, ) = usdcLoan.getLoanDetails(tokenId);
        assertEq(usdcBalanceAfter, 0); // Loan should be paid off
        
        // Test that we can claim the collateral from the AERO contract
        aero.approve(address(aeroLoan), aeroBalance);
        aeroLoan.pay(tokenId, aeroBalance);
        aeroLoan.claimCollateral(tokenId);
        
        // Verify the NFT is back with the user
        assertEq(votingEscrow.ownerOf(tokenId), user);
        vm.stopPrank();
    }
    
    // Helper to deploy a mock ODOS router that actually performs swaps
    function deployMockOdosRouter() internal returns (address) {
        // Get the hardcoded ODOS router address from the Loan contract
        address hardcodedOdosRouter = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
        
        // Deploy a new mock router to get its bytecode
        MockOdosRouter mockRouter = new MockOdosRouter();
        mockRouter.setup(address(usdc), address(aero), address(this));
        
        // Get the code of our mock router
        bytes memory mockCode = address(mockRouter).code;
        
        // Replace the code at the hardcoded router address with our mock code
        vm.etch(hardcodedOdosRouter, mockCode);
        
        // Initialize the router at the replaced address
        MockOdosRouter(payable(hardcodedOdosRouter)).setup(address(usdc), address(aero), address(this));
        
        console.log("Mock router deployed at hardcoded address:", hardcodedOdosRouter);
        
        return hardcodedOdosRouter;
    }
}

// Mock ODOS Router contract that simulates swaps based on trade data
contract MockOdosRouter {
    IERC20 public usdcToken;
    IERC20 public aeroToken;
    address public testContract;
    
    function setup(address _usdcToken, address _aeroToken, address _testContract) external {
        usdcToken = IERC20(_usdcToken);
        aeroToken = IERC20(_aeroToken);
        testContract = _testContract;
    }
    
    // Handle receive function for compatibility
    receive() external payable {
        // Simple fallback - would be triggered if ETH is sent
    }
    
    // Execute the swap with properly defined function interface
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external returns (bool) {
        // Process the swap based on token addresses
        if (tokenIn == address(usdcToken) && tokenOut == address(aeroToken)) {
            // USDC to AERO swap
            // Transfer the exact amount of USDC from sender to this contract
            usdcToken.transferFrom(msg.sender, address(this), amountIn);
            
            // Mint the specified amount of AERO to the sender
            address aeroWhale = 0x40EbC1Ac8d4Fedd2E144b75fe9C0420BE82750c6;
            
            // Call the test contract to mint tokens
            (bool success,) = testContract.call(
                abi.encodeWithSignature(
                    "mintAero(address,address,uint256)",
                    aeroWhale, msg.sender, amountOut
                )
            );
            require(success, "Failed to mint AERO");
        } 
        else if (tokenIn == address(aeroToken) && tokenOut == address(usdcToken)) {
            // AERO to USDC swap
            // Transfer the exact amount of AERO from sender to this contract
            aeroToken.transferFrom(msg.sender, address(this), amountIn);
            
            // Mint the specified amount of USDC to the sender
            address usdcMinter = IUSDC(address(usdcToken)).masterMinter();
            
            // Call the test contract to mint tokens
            (bool success,) = testContract.call(
                abi.encodeWithSignature(
                    "mintUsdc(address,address,uint256)",
                    usdcMinter, msg.sender, amountOut
                )
            );
            require(success, "Failed to mint USDC");
        }
        
        return true;
    }
}
