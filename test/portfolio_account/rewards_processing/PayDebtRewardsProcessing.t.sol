// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {Setup} from "../utils/Setup.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSDC} from "../../../src/interfaces/IUSDC.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DeployRewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployRewardsProcessingFacet.s.sol";
import {DeployLendingFacet} from "../../../script/portfolio_account/facets/DeployLendingFacet.s.sol";
import {DeployCollateralFacet} from "../../../script/portfolio_account/facets/DeployCollateralFacet.s.sol";
import {DeployERC721ReceiverFacet} from "../../../script/portfolio_account/facets/DeployERC721ReceiverFacet.s.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Loan} from "../../../src/Loan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../../../src/VaultV2.sol";

/**
 * @title PayDebtRewardsProcessingTest
 * @dev Tests for the PayDebt rewards option in RewardsProcessingFacet
 * Tests the functionality that allows rewards from one portfolio to pay down debt on another portfolio
 */
contract PayDebtRewardsProcessingTest is Test, Setup {
    RewardsProcessingFacet public rewardsProcessingFacet;

    // Second factory setup (complete with its own config, loan, vault)
    PortfolioFactory public _portfolioFactory2;
    FacetRegistry public _facetRegistry2;
    PortfolioAccountConfig public _portfolioAccountConfig2;
    LoanConfig public _loanConfig2;
    SwapConfig public _swapConfig2;
    address public _portfolioAccount2;
    address public _loanContract2;
    address public _vault2;

    address public rewardsToken;
    uint256 public rewardsAmount = 1000e6; // 1000 USDC
    uint256 public _tokenId2 = 67859; // Second veNFT for portfolio 2

    function setUp() public override {
        super.setUp();

        // Deploy RewardsProcessingFacet for factory 1
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_swapConfig), address(_ve), _vault);
        vm.stopPrank();

        // Initialize facet reference
        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);
        rewardsToken = address(_usdc);
    }

    /**
     * @dev Deploy a second portfolio factory with its own complete configuration
     * including its own PortfolioAccountConfig, LoanConfig, loan contract, and vault
     */
    function deploySecondFactory() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Deploy second factory via PortfolioManager
        bytes32 salt2 = keccak256(abi.encodePacked("aerodrome-usdc-2"));
        (_portfolioFactory2, _facetRegistry2) = _portfolioManager.deployFactory(salt2);

        // Deploy config contracts for factory 2 directly (not using the deployer script)
        deployConfigsForFactory2();

        // Deploy fresh Loan contract for factory 2
        Loan loanImplementation2 = new Loan();
        ERC1967Proxy loanProxy2 = new ERC1967Proxy(address(loanImplementation2), "");
        _loanContract2 = address(loanProxy2);

        // Create vault for factory 2
        Vault vaultImplementation2 = new Vault();
        ERC1967Proxy vaultProxy2 = new ERC1967Proxy(address(vaultImplementation2), "");
        Vault vault2 = Vault(address(vaultProxy2));

        // Initialize vault 2
        vault2.initialize(address(_usdc), _loanContract2, "40base-USDC-VAULT-2", "40base-USDC-VAULT-2");

        // Initialize loan 2
        Loan(_loanContract2).initialize(address(vault2), _usdc);
        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(_loanContract2).upgradeToAndCall(address(loanV2Impl), new bytes(0));

        _vault2 = address(vault2);

        // Configure loan config for factory 2
        _loanConfig2.setRewardsRate(10000);
        _loanConfig2.setMultiplier(100);
        _loanConfig2.setLenderPremium(2000);
        _loanConfig2.setTreasuryFee(500);
        _loanConfig2.setZeroBalanceFee(100);

        // Set loan contract and loan config in PortfolioAccountConfig2
        _portfolioAccountConfig2.setLoanContract(_loanContract2);
        _portfolioAccountConfig2.setLoanConfig(address(_loanConfig2));

        // Set portfolio factory on loan contract 2
        LoanV2(_loanContract2).setPortfolioFactory(address(_portfolioFactory2));

        // Deploy all facets for factory 2 (including LendingFacet)
        deployFacetsForFactory2();

        vm.stopPrank();

        // Create portfolio account 2 for the same user
        _portfolioAccount2 = _portfolioFactory2.createAccount(_user);

        // Transfer a veNFT to portfolio 2
        vm.startPrank(IVotingEscrow(_ve).ownerOf(_tokenId2));
        IVotingEscrow(_ve).transferFrom(IVotingEscrow(_ve).ownerOf(_tokenId2), _portfolioAccount2, _tokenId2);
        vm.stopPrank();
    }

    /**
     * @dev Deploy config contracts for factory 2 directly
     */
    function deployConfigsForFactory2() internal {
        // Deploy PortfolioAccountConfig
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        _portfolioAccountConfig2 = PortfolioAccountConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioAccountConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        // Deploy VotingConfig
        VotingConfig votingConfigImpl = new VotingConfig();
        VotingConfig votingConfig2 = VotingConfig(
            address(new ERC1967Proxy(
                address(votingConfigImpl),
                abi.encodeCall(VotingConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        // Deploy LoanConfig
        LoanConfig loanConfigImpl = new LoanConfig();
        _loanConfig2 = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        // Deploy SwapConfig
        SwapConfig swapConfigImpl = new SwapConfig();
        _swapConfig2 = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        // Link configs together
        _portfolioAccountConfig2.setVoteConfig(address(votingConfig2));
        _portfolioAccountConfig2.setLoanConfig(address(_loanConfig2));
    }

    /**
     * @dev Deploy all necessary facets for the second factory using factory 2's own config
     */
    function deployFacetsForFactory2() internal {
        // Deploy CollateralFacet for factory 2
        DeployCollateralFacet deployCollateral = new DeployCollateralFacet();
        deployCollateral.deploy(address(_portfolioFactory2), address(_portfolioAccountConfig2), address(_ve));

        // Deploy LendingFacet for factory 2
        DeployLendingFacet deployLending = new DeployLendingFacet();
        deployLending.deploy(address(_portfolioFactory2), address(_portfolioAccountConfig2), address(_usdc));

        // Deploy ERC721ReceiverFacet for factory 2
        DeployERC721ReceiverFacet deployReceiver = new DeployERC721ReceiverFacet();
        deployReceiver.deploy(address(_portfolioFactory2));

        // Deploy RewardsProcessingFacet for factory 2
        DeployRewardsProcessingFacet deployRewards = new DeployRewardsProcessingFacet();
        deployRewards.deploy(address(_portfolioFactory2), address(_portfolioAccountConfig2), address(_swapConfig2), address(_ve), _vault2);
    }

    /**
     * @dev Deploy a second portfolio factory WITHOUT LendingFacet for testing graceful failure
     */
    function deploySecondFactoryWithoutLending() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Deploy second factory via PortfolioManager
        bytes32 salt2 = keccak256(abi.encodePacked("aerodrome-usdc-no-lending"));
        (_portfolioFactory2, _facetRegistry2) = _portfolioManager.deployFactory(salt2);

        // Deploy config contracts for factory 2 directly
        deployConfigsForFactory2();

        // Deploy fresh Loan contract for factory 2
        Loan loanImplementation2 = new Loan();
        ERC1967Proxy loanProxy2 = new ERC1967Proxy(address(loanImplementation2), "");
        _loanContract2 = address(loanProxy2);

        // Create vault for factory 2
        Vault vaultImplementation2 = new Vault();
        ERC1967Proxy vaultProxy2 = new ERC1967Proxy(address(vaultImplementation2), "");
        Vault vault2 = Vault(address(vaultProxy2));

        // Initialize vault 2
        vault2.initialize(address(_usdc), _loanContract2, "40base-USDC-VAULT-NL", "40base-USDC-VAULT-NL");

        // Initialize loan 2
        Loan(_loanContract2).initialize(address(vault2), _usdc);
        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(_loanContract2).upgradeToAndCall(address(loanV2Impl), new bytes(0));

        _vault2 = address(vault2);

        // Configure loan config for factory 2
        _loanConfig2.setRewardsRate(10000);
        _loanConfig2.setMultiplier(100);
        _loanConfig2.setLenderPremium(2000);
        _loanConfig2.setTreasuryFee(500);
        _loanConfig2.setZeroBalanceFee(100);

        // Set loan contract and loan config in PortfolioAccountConfig2
        _portfolioAccountConfig2.setLoanContract(_loanContract2);
        _portfolioAccountConfig2.setLoanConfig(address(_loanConfig2));

        // Deploy facets WITHOUT LendingFacet
        deployFacetsForFactory2WithoutLending();

        vm.stopPrank();

        // Create portfolio account 2 for the same user
        _portfolioAccount2 = _portfolioFactory2.createAccount(_user);
    }

    /**
     * @dev Deploy facets for factory 2 without LendingFacet
     */
    function deployFacetsForFactory2WithoutLending() internal {
        // Deploy CollateralFacet for factory 2
        DeployCollateralFacet deployCollateral = new DeployCollateralFacet();
        deployCollateral.deploy(address(_portfolioFactory2), address(_portfolioAccountConfig2), address(_ve));

        // Deploy ERC721ReceiverFacet for factory 2
        DeployERC721ReceiverFacet deployReceiver = new DeployERC721ReceiverFacet();
        deployReceiver.deploy(address(_portfolioFactory2));

        // NOTE: Deliberately NOT deploying LendingFacet for this factory

        // Deploy RewardsProcessingFacet for factory 2
        DeployRewardsProcessingFacet deployRewards = new DeployRewardsProcessingFacet();
        deployRewards.deploy(address(_portfolioFactory2), address(_portfolioAccountConfig2), address(_swapConfig2), address(_ve), _vault2);
    }

    /**
     * @dev Helper to mint USDC to an address
     */
    function mintUSDC(address to, uint256 amount) internal {
        address minter = IUSDC(address(_usdc)).masterMinter();
        vm.startPrank(minter);
        IUSDC(address(_usdc)).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(address(_usdc)).mint(to, amount);
    }

    /**
     * @dev Helper to fund rewards on portfolio 1 (source)
     */
    function setupRewardsOnPortfolio1(uint256 amount) internal {
        mintUSDC(_portfolioAccount, amount);
    }

    /**
     * @dev Helper to setup debt on portfolio 2 (recipient) in factory 2
     */
    function setupDebtOnPortfolio2(uint256 borrowAmount) internal {
        // Add collateral to portfolio 2
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory2);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId2);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Fund vault 2 so borrow can succeed
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        mintUSDC(_vault2, vaultBalance);

        // Borrow to create debt on portfolio 2
        vm.startPrank(_user);
        portfolioFactories[0] = address(_portfolioFactory2);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, borrowAmount);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    /**
     * @dev Helper to configure PayDebt option on portfolio 1
     */
    function setPayDebtOption(address recipient, uint256 percentage) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](4);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        portfolioFactories[2] = address(_portfolioFactory);
        portfolioFactories[3] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](4);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            rewardsToken
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRecipient.selector,
            recipient
        );
        calldatas[2] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.PayDebt
        );
        calldatas[3] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            percentage
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    /**
     * @dev Test 1: PayDebt Successfully Pays Down Debt on Another Portfolio
     *
     * Scenario: User A has two portfolio accounts (in different factories).
     * Portfolio 2 has debt. Portfolio 1 sets recipient to Portfolio 2 with PayDebt option.
     * When rewards are processed on Portfolio 1, they pay down Portfolio 2's debt.
     */
    function testPayDebtSuccessfullyPaysDownDebtOnAnotherPortfolio() public {
        // Setup: Deploy second factory with all facets and its own config
        deploySecondFactory();

        // Setup debt on portfolio 2
        uint256 borrowAmount = 500e6; // 500 USDC
        setupDebtOnPortfolio2(borrowAmount);

        // Verify portfolio 2 has debt
        uint256 debtBefore = CollateralFacet(_portfolioAccount2).getTotalDebt();
        assertGt(debtBefore, 0, "Portfolio 2 should have debt");

        // Setup: Configure PayDebt option on portfolio 1
        uint256 payDebtPercentage = 100; // 100% of rewards to pay debt
        setPayDebtOption(_portfolioAccount2, payDebtPercentage);

        // Setup: Fund portfolio 1 with rewards
        setupRewardsOnPortfolio1(rewardsAmount);

        // Verify portfolio 1 has rewards
        uint256 portfolio1BalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        assertEq(portfolio1BalanceBefore, rewardsAmount, "Portfolio 1 should have rewards");

        // Add collateral to portfolio 1 to ensure it's properly configured
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Execute: Process rewards on portfolio 1
        vm.startPrank(_authorizedCaller);

        // Expect DebtPaid event
        vm.expectEmit(false, true, false, false);
        emit RewardsProcessingFacet.DebtPaid(0, _tokenId, 0, _portfolioAccount2, rewardsToken);

        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0), // no swap
            0, // minimum output amount
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();

        // Assertions
        uint256 debtAfter = CollateralFacet(_portfolioAccount2).getTotalDebt();

        // Debt should have decreased
        assertLt(debtAfter, debtBefore, "Portfolio 2's debt should have decreased");

        // Calculate expected debt reduction
        // PayDebt takes a percentage of rewardsAmount
        uint256 amountToPay = rewardsAmount * payDebtPercentage / 100;

        // Expected debt after payment (accounting for potential excess refund)
        if (amountToPay >= debtBefore) {
            assertEq(debtAfter, 0, "Debt should be fully paid");
        } else {
            assertEq(debtAfter, debtBefore - amountToPay, "Debt should be reduced by payment amount");
        }

        // Verify final balances with exact accounting:
        //
        // Flow when source (portfolio 1) has no debt and target (portfolio 2) has 500e6 debt:
        // 1. getRewardsOptionPercentage() caps 100% to 99% (100% - 1% ZBF) when source has no debt
        // 2. _payDebt sends 990e6 to LendingFacet.pay() on portfolio 2
        // 3. pay() transfers 990e6 from portfolio 1 → portfolio 2
        // 4. pay() pays 500e6 debt, refunds 490e6 excess back to portfolio 1
        // 5. _payDebt returns amountPaid = 500e6 (actual debt reduction)
        // 6. remaining = 1000e6 - 500e6 = 500e6
        // 7. _finalizeRewards → _processZeroBalanceRewards takes 10e6 ZBF (1% of 1000e6)
        // 8. Remaining 490e6 sent to recipient (portfolio 2)
        //
        // Final token movements from portfolio 1:
        //   -990e6 (to portfolio 2 via pay)
        //   +490e6 (refund from pay)
        //   -10e6  (ZBF to loan contract)
        //   -490e6 (to recipient in _processZeroBalanceRewards)
        //   = 0

        uint256 portfolio1BalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        assertEq(portfolio1BalanceAfter, 0, "Portfolio 1 should have 0 balance after processing");

        // Portfolio 2 receives 490e6 from _processZeroBalanceRewards (remaining after ZBF)
        uint256 portfolio2BalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount2);
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 expectedZBF = (rewardsAmount * zeroBalanceFee) / 10000; // 10e6
        uint256 expectedRecipientAmount = (rewardsAmount - debtBefore) - expectedZBF; // 500e6 - 10e6 = 490e6
        assertEq(portfolio2BalanceAfter, expectedRecipientAmount, "Portfolio 2 should receive remaining after ZBF");
    }

    /**
     * @dev Test 2: PayDebt Fails Gracefully When Portfolio Has No pay() Method
     *
     * Scenario: Portfolio 1 sets recipient to Portfolio 2, but Portfolio 2 doesn't have
     * LendingFacet registered. The pay() call fails (returns 0), and the full remaining
     * amount flows to _finalizeRewards unchanged.
     */
    function testPayDebtFailsGracefullyWhenNoPayMethod() public {
        // Setup: Deploy second factory WITHOUT LendingFacet
        deploySecondFactoryWithoutLending();

        // Verify portfolio 2 is registered
        assertTrue(
            _portfolioManager.isPortfolioRegistered(_portfolioAccount2),
            "Portfolio 2 should be registered"
        );

        // Setup: Configure PayDebt option on portfolio 1 (source) with 50% to pay debt
        uint256 payDebtPercentage = 50;
        setPayDebtOption(_portfolioAccount2, payDebtPercentage);

        // Setup: Fund portfolio 1 with rewards
        setupRewardsOnPortfolio1(rewardsAmount);

        uint256 portfolio2BalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount2);

        // Add collateral to portfolio 1
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Execute: Process rewards on portfolio 1 - should NOT revert
        vm.startPrank(_authorizedCaller);

        // Note: We expect ZeroBalanceRewardsProcessed event instead of DebtPaid
        // because the pay() call will fail and the full amount will go to finalizeRewards

        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0), // no swap
            0, // minimum output amount
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();

        // Assertions

        // No DebtPaid event should have been emitted (we can't check for absence, but we can check balances)

        // Portfolio 1 should have processed all rewards
        uint256 portfolio1BalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        assertEq(portfolio1BalanceAfter, 0, "Portfolio 1 should have no remaining rewards");

        // Portfolio 2 should have received the rewards (via _processZeroBalanceRewards -> recipient transfer)
        // since portfolio 1 has no debt, _finalizeRewards calls _processZeroBalanceRewards
        // which sends remaining to recipient (minus zero balance fee)
        uint256 portfolio2BalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount2);

        // Calculate expected amount after zero balance fee (1% = 100 basis points)
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedRecipientAmount = rewardsAmount - feeAmount;

        // The full rewards (minus zero balance fee) should go to recipient
        // because _payDebt returns 0 when pay() fails
        assertEq(
            portfolio2BalanceAfter,
            portfolio2BalanceBefore + expectedRecipientAmount,
            "Portfolio 2 should receive full rewards minus zero balance fee"
        );
    }

    /**
     * @dev Test that PayDebt returns 0 when recipient is not a registered portfolio
     */
    function testPayDebtReturnsZeroWhenRecipientNotRegisteredPortfolio() public {
        // Setup: Set recipient to a non-portfolio address
        address nonPortfolioRecipient = address(0xDEAD);

        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](4);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        portfolioFactories[2] = address(_portfolioFactory);
        portfolioFactories[3] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](4);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            rewardsToken
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRecipient.selector,
            nonPortfolioRecipient
        );
        calldatas[2] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.PayDebt
        );
        calldatas[3] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            50
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Add collateral to portfolio 1
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Setup: Fund portfolio 1 with rewards
        setupRewardsOnPortfolio1(rewardsAmount);

        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(nonPortfolioRecipient);

        // Execute: Process rewards - should not revert
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            0
        );
        vm.stopPrank();

        // Assertions
        // Since PayDebt returns 0 (recipient not registered), full rewards go to recipient via _processZeroBalanceRewards
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(nonPortfolioRecipient);

        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedAmount = rewardsAmount - feeAmount;

        assertEq(
            recipientBalanceAfter,
            recipientBalanceBefore + expectedAmount,
            "Non-portfolio recipient should receive rewards minus fee"
        );
    }

    /**
     * @dev Test PayDebt with partial debt payment when rewards exceed debt
     */
    function testPayDebtPartialPaymentWhenRewardsExceedDebt() public {
        // Setup: Deploy second factory with all facets and its own config
        deploySecondFactory();

        // Setup: Create small debt on portfolio 2 (less than rewards)
        uint256 smallBorrowAmount = 200e6; // 200 USDC debt (less than 1000 USDC rewards)
        setupDebtOnPortfolio2(smallBorrowAmount);

        uint256 debtBefore = CollateralFacet(_portfolioAccount2).getTotalDebt();
        assertGt(debtBefore, 0, "Portfolio 2 should have debt");
        assertLt(debtBefore, rewardsAmount, "Debt should be less than rewards for this test");

        // Setup: Configure PayDebt option on portfolio 1
        setPayDebtOption(_portfolioAccount2, 100);

        // Setup: Fund portfolio 1 with rewards
        setupRewardsOnPortfolio1(rewardsAmount);

        // Add collateral to portfolio 1
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        _portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Execute: Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            0
        );
        vm.stopPrank();

        // Assertions
        uint256 debtAfter = CollateralFacet(_portfolioAccount2).getTotalDebt();

        // Debt should be fully paid (rewards exceed debt)
        assertEq(debtAfter, 0, "Debt should be fully paid when rewards exceed debt");
    }
}
