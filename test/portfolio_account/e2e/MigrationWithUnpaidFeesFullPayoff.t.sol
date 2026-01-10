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
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {Setup} from "../utils/Setup.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

/**
 * @title MigrationWithUnpaidFeesTest
 * @dev E2E test for migrating a LoanV2 loan to portfolio account with unpaid fees
 *      Uses actual Base loan contract and tokenId 83558
 */
contract MigrationWithUnpaidFeesTest is Test {
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
    PortfolioAccountConfig public portfolioAccountConfig;
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
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (portfolioAccountConfig, , loanConfig, swapConfig) = configDeployer.deploy();
        
        // Deploy facets
        DeployFacets deployer = new DeployFacets();
        deployer.deploy(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            address(0), // votingConfig - not needed for this test
            address(ve),
            address(0), // voter - not needed
            address(0), // rewardsDistributor - not needed
            address(loanConfig),
            address(usdc),
            address(swapConfig), // swapConfig
            BASE_LOAN_CONTRACT, // loanContract
            address(usdc), // lendingToken
            loanContract._vault()
        );
        
        // Set loan contract in config
        portfolioAccountConfig.setLoanContract(BASE_LOAN_CONTRACT);
        vm.stopPrank();
        
        // Set portfolio factory on loan contract (if not already set)
        // Use try-catch in case getPortfolioFactory() reverts (e.g., if not implemented on forked contract)
        if(loanContract.getPortfolioFactory()== address(0)) {
            vm.prank(loanContract.owner());
            loanContract.setPortfolioFactory(address(portfolioFactory));
        }
        
        
        // Create portfolio account for user
        vm.startPrank(user);
        portfolioAccount = portfolioFactory.createAccount(user);
        vm.stopPrank();
        
        console.log("Portfolio Account:", portfolioAccount);
    }

    function testMigrateLoanWithUnpaidFeesFullPayoff() public {
        // Verify initial state
        (uint256 initialBalance, address initialBorrower) = loanContract.getLoanDetails(TOKEN_ID);
        require(initialBorrower == user, "User must be the borrower");
        require(initialBalance > 0, "Loan must have a balance");
        
        // Get initial unpaid fees from loan contract storage
        // _loanDetails is a public mapping, so we can access it
        // unpaidFees is at index 10 in the LoanInfo struct
        uint256 initialUnpaidFees = _getUnpaidFees(TOKEN_ID);
        
        console.log("Initial Loan Balance:", initialBalance);
        console.log("Initial Unpaid Fees:", initialUnpaidFees);
        
        // Verify unpaid fees are present (should be around 4.82 USDC)
        require(initialUnpaidFees > 0, "Loan must have unpaid fees");
        console.log("Unpaid Fees (USDC):", initialUnpaidFees / 1e6);
        
        // Get initial protocol owner balance
        uint256 protocolOwnerBalanceBefore = usdc.balanceOf(protocolOwner);
        console.log("Protocol Owner Balance Before:", protocolOwnerBalanceBefore);
        
        // Migrate the loan to portfolio account
        vm.startPrank(user);
        loanContract.migrateToPortfolio(TOKEN_ID);
        vm.stopPrank();
        
        // Verify migration
        address tokenOwner = ve.ownerOf(TOKEN_ID);
        assertEq(tokenOwner, portfolioAccount, "Token should be in portfolio account");
        
        // Verify debt was migrated
        uint256 portfolioDebt = CollateralFacet(portfolioAccount).getTotalDebt();
        uint256 portfolioUnpaidFees = CollateralFacet(portfolioAccount).getUnpaidFees();
        
        console.log("Portfolio Debt:", portfolioDebt);
        console.log("Portfolio Unpaid Fees:", portfolioUnpaidFees);
        
        assertEq(portfolioDebt, initialBalance, "Portfolio debt should match initial loan balance");
        assertEq(portfolioUnpaidFees, initialUnpaidFees, "Portfolio unpaid fees should match initial unpaid fees");
        
        // Now pay down the loan - unpaid fees should go to protocol owner first
        uint256 paymentAmount = initialBalance; // Pay full balance
        uint256 totalPaymentNeeded = paymentAmount + initialUnpaidFees; // Need to pay balance + fees
        
        // Fund portfolio account with USDC for payment (including fees)
        deal(address(usdc), portfolioAccount, totalPaymentNeeded);
        
        // Approval is handled inside decreaseTotalDebt (via delegatecall from portfolio account)
        // Now execute the payment as the portfolio owner
        address portfolioOwner = PortfolioFactory(portfolioFactory).ownerOf(portfolioAccount);
        vm.startPrank(portfolioOwner);
        
        deal(address(usdc), portfolioOwner, paymentAmount);
        IERC20(usdc).approve(portfolioAccount, paymentAmount);
        // Pay via multicall (using LendingFacet)
        bytes memory payCalldata = abi.encodeWithSelector(
            LendingFacet.pay.selector,
            paymentAmount
        );
        
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = payCalldata;
        
        PortfolioManager(address(portfolioManager)).multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        // Verify unpaid fees were paid to protocol owner first
        uint256 protocolOwnerBalanceAfter = usdc.balanceOf(protocolOwner);
        uint256 feesPaidToOwner = protocolOwnerBalanceAfter - protocolOwnerBalanceBefore;
        
        console.log("Protocol Owner Balance After:", protocolOwnerBalanceAfter);
        console.log("Fees Paid to Protocol Owner:", feesPaidToOwner);
        console.log("Fees Paid (USDC):", feesPaidToOwner / 1e6);
        
        // Fees should be paid (capped at 25% of payment amount)
        uint256 maxFees = paymentAmount;
        uint256 expectedFeesPaid = initialUnpaidFees > maxFees ? maxFees : initialUnpaidFees;
        
        assertGe(feesPaidToOwner, expectedFeesPaid);
        assertLe(feesPaidToOwner, maxFees);
        
        // Verify debt was decreased
        uint256 portfolioDebtAfter = CollateralFacet(portfolioAccount).getTotalDebt();
        console.log("Portfolio Debt After Payment:", portfolioDebtAfter);
        
        // Calculate expected debt reduction
        uint256 debtReduction = paymentAmount - expectedFeesPaid;
        uint256 expectedDebtAfter = initialBalance > debtReduction ? initialBalance - debtReduction : 0;
        assertEq(portfolioDebtAfter, expectedDebtAfter, "Portfolio debt should be reduced by (paymentAmount - expectedFeesPaid)");
        
        // Verify unpaid fees were reduced
        uint256 portfolioUnpaidFeesAfter = CollateralFacet(portfolioAccount).getUnpaidFees();
        uint256 expectedUnpaidFeesAfter = initialUnpaidFees > expectedFeesPaid ? initialUnpaidFees - expectedFeesPaid : 0;
        assertEq(portfolioUnpaidFeesAfter, expectedUnpaidFeesAfter, "Unpaid fees should be reduced by expectedFeesPaid");
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

