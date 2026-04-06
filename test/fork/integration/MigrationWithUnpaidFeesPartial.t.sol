// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {Setup} from "../portfolio_account/utils/Setup.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

/**
 * @title MigrationWithUnpaidFeesTest
 * @dev E2E test for migrating a LoanV2 loan to portfolio account with unpaid fees
 *      Uses actual Base loan contract and tokenId 83558
 */
contract MigrationWithUnpaidFeesPartialPayoffTest is Test {
    // Base network addresses
    address constant BASE_LOAN_CONTRACT = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_VE = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    uint256 constant TOKEN_ID = 83558;
    address constant FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    
    LoanV2 public loanContract;
    IERC20 public usdc;
    IVotingEscrow public ve;
    PortfolioFactory public portfolioFactory;
    PortfolioManager public portfolioManager;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LoanConfig public loanConfig;
    SwapConfig public swapConfig;
    FacetRegistry public facetRegistry;
    address public user;
    address public portfolioAccount;
    address public protocolOwner;

    function setUp() public {
        // Fork Base network
        uint256 fork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(39141595);
        
        // Get the actual loan contract
        loanContract = LoanV2(payable(BASE_LOAN_CONTRACT));
        usdc = IERC20(BASE_USDC);
        ve = IVotingEscrow(BASE_VE);
        
        // Get protocol owner
        protocolOwner = loanContract.owner();

        // upgrade the loan contract
        LoanV2 loanV2 = new LoanV2();
        vm.prank(loanContract.owner());
        loanContract.upgradeToAndCall(address(loanV2), new bytes(0));
        
        // Get the actual borrower of tokenId 83558
        (uint256 balance, address borrower) = loanContract.getLoanDetails(TOKEN_ID);
        require(borrower != address(0), "Token must have a borrower");
        require(balance > 0, "Token must have a loan balance");
        user = borrower;
        
        console.log("Token ID:", TOKEN_ID);
        console.log("Borrower:", user);
        console.log("Loan Balance:", balance);
        
        // Deploy portfolio infrastructure
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        portfolioManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (portfolioFactory, facetRegistry) = portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("base-migration-test"))));
        
        // Deploy config contracts
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (portfolioFactoryConfig, , loanConfig, swapConfig) = configDeployer.deploy(address(portfolioFactory));
        
        // Deploy facets
        DeployFacets deployer = new DeployFacets();
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        deployer.deploy(
            address(portfolioFactory),
            address(0), // votingConfig - not needed for this test
            address(ve),
            address(0), // voter - not needed
            address(0), // rewardsDistributor - not needed
            address(loanConfig),
            address(usdc),
            address(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d),
            address(swapConfig), // swapConfig
            BASE_LOAN_CONTRACT, // loanContract
            address(usdc), // lendingToken
            loanContract._vault()
        );
        
        vm.stopPrank();

        // Set portfolio factory on loan contract BEFORE setting loan contract in config
        // (config validates that loan.getPortfolioFactory() == portfolioFactory)
        if(loanContract.getPortfolioFactory()== address(0)) {
            vm.prank(loanContract.owner());
            loanContract.setPortfolioFactory(address(portfolioFactory));
        }

        // Now set loan contract in config (validation will pass)
        vm.prank(FORTY_ACRES_DEPLOYER);
        portfolioFactoryConfig.setLoanContract(BASE_LOAN_CONTRACT);
        
        
        // Create portfolio account for user
        vm.startPrank(user);
        portfolioAccount = portfolioFactory.createAccount(user);
        vm.stopPrank();
        
        console.log("Portfolio Account:", portfolioAccount);
    }

    function testMigrateLoanWithUnpaidFees() public {
        // Verify initial state
        (uint256 initialBalance, address initialBorrower) = loanContract.getLoanDetails(TOKEN_ID);
        require(initialBorrower == user, "User must be the borrower");
        require(initialBalance > 0, "Loan must have a balance");

        // Get initial unpaid fees from loan contract storage
        uint256 initialUnpaidFees = _getUnpaidFees(TOKEN_ID);

        console.log("Initial Loan Balance:", initialBalance);
        console.log("Initial Unpaid Fees:", initialUnpaidFees);

        // Verify unpaid fees are present (should be around 4.82 USDC)
        require(initialUnpaidFees > 0, "Loan must have unpaid fees");

        // Get initial protocol owner balance
        uint256 protocolOwnerBalanceBefore = usdc.balanceOf(protocolOwner);

        // Step 1: Pay off unpaid fees on LoanV2 (required: loan.unpaidFees must be 0 to migrate)
        deal(address(usdc), user, initialUnpaidFees);
        vm.startPrank(user);
        usdc.approve(address(loanContract), initialUnpaidFees);
        loanContract.pay(TOKEN_ID, initialUnpaidFees);
        vm.stopPrank();

        // Verify unpaid fees are cleared and owner received them
        assertEq(_getUnpaidFees(TOKEN_ID), 0, "Unpaid fees should be cleared before migration");
        assertEq(usdc.balanceOf(protocolOwner) - protocolOwnerBalanceBefore, initialUnpaidFees, "Owner should receive fees");

        // Re-read balance after fee payment
        (uint256 balanceAfterFeePayment,) = loanContract.getLoanDetails(TOKEN_ID);

        // Step 2: Migrate (only owner can migrate)
        vm.prank(protocolOwner);
        loanContract.migrateToPortfolio(TOKEN_ID);

        // Verify migration
        assertEq(ve.ownerOf(TOKEN_ID), portfolioAccount, "Token should be in portfolio account");

        // Verify debt was migrated
        uint256 portfolioDebt = CollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(portfolioDebt, balanceAfterFeePayment, "Portfolio debt should match remaining balance");

        // Step 3: Partial payment in portfolio
        address portfolioOwner = PortfolioFactory(portfolioFactory).ownerOf(portfolioAccount);
        address vault = ILoan(BASE_LOAN_CONTRACT)._vault();
        uint256 partialPayment = 10000; // 0.01 USDC
        uint256 vaultBalanceBefore = usdc.balanceOf(vault);

        vm.startPrank(portfolioOwner);
        deal(address(usdc), portfolioOwner, partialPayment);
        IERC20(usdc).approve(portfolioAccount, partialPayment);

        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.pay.selector, partialPayment);

        PortfolioManager(address(portfolioManager)).multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Verify partial payment went to vault (no unpaid fees in portfolio)
        uint256 vaultBalanceAfter = usdc.balanceOf(vault);
        assertEq(vaultBalanceAfter - vaultBalanceBefore, partialPayment, "Payment should go to vault");

        // Verify debt reduced
        uint256 debtAfter = CollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, balanceAfterFeePayment - partialPayment, "Debt should decrease by payment amount");
    }
    
    /**
     * @dev Helper function to get unpaid fees from loan contract storage
     */
    function _getUnpaidFees(uint256 tokenId) internal view returns (uint256) {
        LoanV2 loanV2 = LoanV2(BASE_LOAN_CONTRACT);
        (,,,,,,,,,uint256 unpaidFees,,,,) = loanV2._loanDetails(tokenId);
        return unpaidFees;
    }
}

