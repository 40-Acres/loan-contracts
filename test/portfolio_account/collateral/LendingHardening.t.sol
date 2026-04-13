// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {IPortfolioFactory} from "../../../src/accounts/IPortfolioFactory.sol";

import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";

import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";

import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LocalSetup} from "../utils/LocalSetup.sol";


contract LendingHardeningTest is Test, LocalSetup {

    uint256 constant MAX_LOAN_IGNORE_SUPPLY = 5e9;
    uint256 constant BORROW_AMOUNT = 3000e6;
    uint256 constant BLOCK_START = 101;

    PortfolioFactory public _portfolioFactory2;
    FacetRegistry public _facetRegistry2;
    PortfolioFactoryConfig public _portfolioFactoryConfig2;
    address public _portfolioAccount2;

    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId);
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    function removeCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    function borrowToViaMulticall(address toFactory, uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseLendingFacet.borrowTo.selector, IPortfolioFactory(toFactory), amount);
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    function payViaLendingFacet(address portfolioAccount, uint256 amount) internal {
        vm.startPrank(_user);
        deal(address(_asset), _user, amount);
        IERC20(address(_asset)).approve(portfolioAccount, amount);
        LendingFacet(portfolioAccount).pay(amount);
        vm.stopPrank();
    }

    function _fundVault(uint256 borrowAmount) internal {
        address loanContract = _portfolioFactoryConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        uint256 needed = (borrowAmount * 10000) / 8000 + 1;
        deal(address(_asset), vault, needed);
    }

    function _makeUnderwater() internal returns (uint256 newMaxLoanIgnoreSupply) {
        vm.startPrank(_owner);
        _loanConfig.setRewardsRate(1);
        vm.stopPrank();
        (, newMaxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
    }

    function _multicallBatch(bytes[] memory data) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            factories[i] = address(_portfolioFactory);
        }
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    function _setupUnderwaterAccount() internal returns (uint256 newMaxLoan) {
        addCollateralViaMulticall(_tokenId);
        _fundVault(BORROW_AMOUNT);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(BORROW_AMOUNT);
        vm.roll(BLOCK_START + 2);
        newMaxLoan = _makeUnderwater();
        uint256 currentDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(currentDebt, newMaxLoan, "Account should be underwater");
    }

    function _deploySecondFactory() internal {
        vm.startPrank(_owner);

        (PortfolioFactory factory2_, FacetRegistry registry2_) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("aerodrome-usdc-2")))
        );
        _portfolioFactory2 = factory2_;
        _facetRegistry2 = registry2_;

        PortfolioFactoryConfig configImpl2 = new PortfolioFactoryConfig();
        _portfolioFactoryConfig2 = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl2),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (_owner, address(_portfolioFactory2)))
            ))
        );
        _portfolioFactoryConfig2.setLoanConfig(address(_loanConfig));

        Loan loanImpl2 = new Loan();
        ERC1967Proxy loanProxy2 = new ERC1967Proxy(address(loanImpl2), "");
        address loanContract2 = address(loanProxy2);

        Vault vaultImpl2 = new Vault();
        ERC1967Proxy vaultProxy2 = new ERC1967Proxy(address(vaultImpl2), "");
        Vault vault2 = Vault(address(vaultProxy2));

        vault2.initialize(_usdc, loanContract2, "40base-USDC-VAULT-2", "40base-USDC-VAULT-2");
        Loan(loanContract2).initialize(address(vault2), _usdc);

        LoanV2 loanV2Impl2 = new LoanV2();
        LoanV2(loanContract2).upgradeToAndCall(address(loanV2Impl2), new bytes(0));
        LoanV2(loanContract2).setPortfolioFactory(address(_portfolioFactory2));

        _portfolioFactoryConfig2.setLoanContract(loanContract2);
        _portfolioFactory2.setPortfolioFactoryConfig(address(_portfolioFactoryConfig2));

        CollateralFacet collateralFacet2 = new CollateralFacet(
            address(_portfolioFactory2), address(_ve)
        );
        bytes4[] memory collateralSel = new bytes4[](10);
        collateralSel[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSel[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSel[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSel[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSel[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSel[6] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSel[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSel[8] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSel[9] = BaseCollateralFacet.removeCollateralTo.selector;
        _facetRegistry2.registerFacet(address(collateralFacet2), collateralSel, "CollateralFacet");

        LendingFacet lendingFacet2 = new LendingFacet(
            address(_portfolioFactory2), _usdc
        );
        bytes4[] memory lendingSel = new bytes4[](5);
        lendingSel[0] = BaseLendingFacet.borrow.selector;
        lendingSel[1] = BaseLendingFacet.pay.selector;
        lendingSel[2] = BaseLendingFacet.setTopUp.selector;
        lendingSel[3] = BaseLendingFacet.topUp.selector;
        lendingSel[4] = BaseLendingFacet.borrowTo.selector;
        _facetRegistry2.registerFacet(address(lendingFacet2), lendingSel, "LendingFacet");

        vm.stopPrank();

        _portfolioAccount2 = _portfolioFactory2.createAccount(_user);
    }

    // --- Underwater account is not bricked ---

    function test_underwaterAccount_canStillVote() public {
        _setupUnderwaterAccount();
        vm.roll(BLOCK_START + 3);

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, false);
        _multicallBatch(data);
    }

    function test_underwaterAccount_canStillPayDebt() public {
        _setupUnderwaterAccount();
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        vm.roll(BLOCK_START + 3);

        payViaLendingFacet(_portfolioAccount, 500e6);

        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, debtBefore - 500e6);
    }

    function test_underwaterAccount_canStillAddCollateral() public {
        _setupUnderwaterAccount();

        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();

        uint256 collateralBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        vm.roll(BLOCK_START + 3);

        addCollateralViaMulticall(_tokenId2);

        assertGt(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), collateralBefore);
    }

    function test_underwaterAccount_cannotBorrow() public {
        _setupUnderwaterAccount();
        _fundVault(200e6);
        vm.roll(BLOCK_START + 3);

        vm.expectRevert(); // BadDebt or UndercollateralizedDebt — both fire, BadDebt checked first on main
        borrowViaMulticall(100e6);
    }

    function test_underwaterAccount_cannotRemoveCollateral() public {
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();

        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(_tokenId2);

        _fundVault(BORROW_AMOUNT);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(BORROW_AMOUNT);

        vm.roll(BLOCK_START + 2);
        _makeUnderwater();

        vm.roll(BLOCK_START + 3);
        vm.expectRevert(bytes("Debt exceeds max loan"));
        removeCollateralViaMulticall(_tokenId2);
    }

    // --- Borrow enforcement ---

    function test_borrowExactlyMaxLoan_succeeds() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);

        uint256 debt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, MAX_LOAN_IGNORE_SUPPLY);

        (uint256 remainingMaxLoan,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(remainingMaxLoan, 0);

        assertTrue(CollateralFacet(_portfolioAccount).enforceCollateralRequirements());
    }

    function test_borrowMaxLoanPlusOne_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        vm.expectRevert(abi.encodeWithSelector(CollateralManager.BadDebt.selector, 1));
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY + 1);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_cannotBorrowAboveVaultSupplyConstraint() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        address loanContract = _portfolioFactoryConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_asset), vault, 1000e6);

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertLt(maxLoan, maxLoanIgnoreSupply);

        uint256 overBorrow = maxLoan + 100e6;
        vm.expectRevert(abi.encodeWithSelector(CollateralManager.BadDebt.selector, 100e6));
        borrowViaMulticall(overBorrow);
    }

    function test_borrowVaultConstrainedExact_succeeds() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        address loanContract = _portfolioFactoryConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_asset), vault, 2000e6);

        (uint256 maxLoan,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertGt(maxLoan, 0);

        borrowViaMulticall(maxLoan);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), maxLoan);
        assertTrue(CollateralFacet(_portfolioAccount).enforceCollateralRequirements());
    }

    function test_twoMulticallsSameBlock_cannotOverBorrow() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        uint256 halfMax = MAX_LOAN_IGNORE_SUPPLY / 2;
        borrowViaMulticall(halfMax);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), halfMax);

        vm.expectRevert();
        borrowViaMulticall(halfMax + 1);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), halfMax);
    }

    function test_splitBorrowAcrossBlocks_atCapacity() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        uint256 half = MAX_LOAN_IGNORE_SUPPLY / 2;
        uint256 remainder = MAX_LOAN_IGNORE_SUPPLY - half;

        borrowViaMulticall(half);
        vm.roll(BLOCK_START + 2);
        borrowViaMulticall(remainder);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY);

        vm.roll(BLOCK_START + 3);
        vm.expectRevert();
        borrowViaMulticall(1);
    }

    // --- borrowTo enforcement ---

    function test_borrowTo_debtOnSourceNotDestination() public {
        _deploySecondFactory();
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(BORROW_AMOUNT);
        borrowToViaMulticall(address(_portfolioFactory2), BORROW_AMOUNT);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), BORROW_AMOUNT);
        assertEq(CollateralFacet(_portfolioAccount2).getTotalDebt(), 0);

        uint256 originationFee = (BORROW_AMOUNT * 80) / 10000;
        assertEq(IERC20(address(_asset)).balanceOf(_portfolioAccount2), BORROW_AMOUNT - originationFee);
    }

    function test_borrowTo_cannotExceedMaxLoan() public {
        _deploySecondFactory();
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        vm.expectRevert(abi.encodeWithSelector(CollateralManager.BadDebt.selector, 1));
        borrowToViaMulticall(address(_portfolioFactory2), MAX_LOAN_IGNORE_SUPPLY + 1);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_crossFactory_doubleDip_reverts() public {
        _deploySecondFactory();
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(BORROW_AMOUNT);
        borrowToViaMulticall(address(_portfolioFactory2), BORROW_AMOUNT);
        vm.roll(BLOCK_START + 2);

        (uint256 factory2MaxLoan,) = CollateralFacet(_portfolioAccount2).getMaxLoan();
        assertEq(factory2MaxLoan, 0);

        address loanContract2 = _portfolioFactoryConfig2.getLoanContract();
        address vault2 = ILoan(loanContract2)._vault();
        deal(address(_asset), vault2, 1000e6);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory2);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 100e6);
        vm.expectRevert();
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    // --- topUp enforcement ---

    function test_topUp_borrowsExactlyMaxLoan() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        bytes[] memory enableData = new bytes[](1);
        enableData[0] = abi.encodeWithSelector(BaseLendingFacet.setTopUp.selector, true);
        _multicallBatch(enableData);
        vm.roll(BLOCK_START + 2);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        vm.prank(_authorizedCaller);
        LendingFacet(_portfolioAccount).topUp();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY);
        (uint256 remainingMaxLoan,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(remainingMaxLoan, 0);
    }

    function test_topUp_unauthorizedCaller_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        bytes[] memory enableData = new bytes[](1);
        enableData[0] = abi.encodeWithSelector(BaseLendingFacet.setTopUp.selector, true);
        _multicallBatch(enableData);
        vm.roll(BLOCK_START + 2);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        vm.prank(address(0xA77AC4));
        vm.expectRevert(abi.encodeWithSelector(CollateralManager.NotPortfolioManager.selector));
        LendingFacet(_portfolioAccount).topUp();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_topUp_atCapacity_noop() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);
        vm.roll(BLOCK_START + 2);

        bytes[] memory enableData = new bytes[](1);
        enableData[0] = abi.encodeWithSelector(BaseLendingFacet.setTopUp.selector, true);
        _multicallBatch(enableData);
        vm.roll(BLOCK_START + 3);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        vm.prank(_authorizedCaller);
        LendingFacet(_portfolioAccount).topUp();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), debtBefore);
    }

    function test_topUp_thenBorrow_sameBlock_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        bytes[] memory enableData = new bytes[](1);
        enableData[0] = abi.encodeWithSelector(BaseLendingFacet.setTopUp.selector, true);
        _multicallBatch(enableData);
        vm.roll(BLOCK_START + 2);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        vm.prank(_authorizedCaller);
        LendingFacet(_portfolioAccount).topUp();
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY);

        vm.expectRevert();
        borrowViaMulticall(1);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY);
    }

    function test_topUp_fundsGoToOwner() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        bytes[] memory enableData = new bytes[](1);
        enableData[0] = abi.encodeWithSelector(BaseLendingFacet.setTopUp.selector, true);
        _multicallBatch(enableData);
        vm.roll(BLOCK_START + 2);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 ownerBalBefore = IERC20(address(_asset)).balanceOf(portfolioOwner);

        vm.prank(_authorizedCaller);
        LendingFacet(_portfolioAccount).topUp();

        assertGt(IERC20(address(_asset)).balanceOf(portfolioOwner), ownerBalBefore);
    }

    // --- Migration enforcement ---

    function test_migrateDebt_onlyCallableByLoanContract() public {
        vm.prank(address(0xDEADBEEF));
        vm.expectRevert();
        MigrationFacet(_portfolioAccount).migrate(_tokenId, 0);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_migrateDebt_cannotCallTwice() public {
        address loanContract = _portfolioFactoryConfig.getLoanContract();

        vm.prank(_portfolioAccount);
        IVotingEscrow(_ve).transferFrom(_portfolioAccount, loanContract, _tokenId);

        uint256 migratedDebt = 2000e6;
        vm.mockCall(
            loanContract,
            abi.encodeWithSignature("getLoanDetails(uint256)", _tokenId),
            abi.encode(migratedDebt, _user)
        );

        vm.startPrank(loanContract);
        IVotingEscrow(_ve).approve(_portfolioAccount, _tokenId);
        MigrationFacet(_portfolioAccount).migrate(_tokenId, 0);
        vm.stopPrank();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), migratedDebt);

        vm.startPrank(loanContract);
        vm.expectRevert();
        MigrationFacet(_portfolioAccount).migrate(_tokenId, 0);
        vm.stopPrank();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), migratedDebt);
    }

    function test_migrateDebt_canExceedMaxLoan_butCannotBorrowMore() public {
        address loanContract = _portfolioFactoryConfig.getLoanContract();

        vm.prank(_portfolioAccount);
        IVotingEscrow(_ve).transferFrom(_portfolioAccount, loanContract, _tokenId);

        uint256 excessiveDebt = MAX_LOAN_IGNORE_SUPPLY + 1000e6;
        vm.mockCall(
            loanContract,
            abi.encodeWithSignature("getLoanDetails(uint256)", _tokenId),
            abi.encode(excessiveDebt, _user)
        );

        vm.startPrank(loanContract);
        IVotingEscrow(_ve).approve(_portfolioAccount, _tokenId);
        MigrationFacet(_portfolioAccount).migrate(_tokenId, 0);
        vm.stopPrank();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), excessiveDebt);
        assertGt(excessiveDebt, MAX_LOAN_IGNORE_SUPPLY);

        vm.roll(BLOCK_START + 1);
        _fundVault(1000e6);
        vm.expectRevert();
        borrowViaMulticall(1);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), excessiveDebt);
    }

    function test_migrationSetsDebtAboveMaxLoan_accountNotBricked() public {
        address loanContract = _portfolioFactoryConfig.getLoanContract();

        vm.prank(_portfolioAccount);
        IVotingEscrow(_ve).transferFrom(_portfolioAccount, loanContract, _tokenId);

        uint256 migratedDebt = 3000e6;
        vm.mockCall(
            loanContract,
            abi.encodeWithSignature("getLoanDetails(uint256)", _tokenId),
            abi.encode(migratedDebt, _user)
        );

        vm.startPrank(loanContract);
        IVotingEscrow(_ve).approve(_portfolioAccount, _tokenId);
        MigrationFacet(_portfolioAccount).migrate(_tokenId, 0);
        vm.stopPrank();

        vm.roll(BLOCK_START + 2);
        _makeUnderwater();

        uint256 debt = CollateralFacet(_portfolioAccount).getTotalDebt();
        (, uint256 maxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertGt(debt, maxLoanIgnoreSupply);

        vm.roll(BLOCK_START + 3);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, false);
        _multicallBatch(data);
    }

    // --- Direct access / authorization ---

    function test_directIncreaseTotalDebt_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        bytes memory callData = abi.encodeWithSelector(
            bytes4(keccak256("increaseTotalDebt(address,uint256)")),
            address(_portfolioFactoryConfig),
            1000e6
        );

        vm.prank(address(_portfolioManager));
        (bool success,) = _portfolioAccount.call(callData);
        assertFalse(success);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_directBorrow_notThroughMulticall_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);
        _fundVault(1000e6);

        vm.prank(_user);
        vm.expectRevert();
        LendingFacet(_portfolioAccount).borrow(1000e6);
    }

    function test_borrowFromRandomAttacker_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);
        _fundVault(1000e6);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        LendingFacet(_portfolioAccount).borrow(1000e6);
    }

    // --- Collateral manipulation ---

    function test_removeCollateral_afterBorrowToMax_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);
        vm.roll(BLOCK_START + 2);

        vm.expectRevert(bytes("Debt exceeds max loan"));
        removeCollateralViaMulticall(_tokenId);

        assertGt(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
    }

    function test_addBorrowRemove_sameMulticall_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();

        _fundVault(7e9);

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId2);
        data[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, uint256(4900e6));
        data[2] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, _tokenId);

        vm.expectRevert(bytes("Debt exceeds max loan"));
        _multicallBatch(data);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_borrowAfterCollateralRemoved_sameMulticall_reverts() public {
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();

        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(_tokenId2);
        vm.roll(BLOCK_START + 1);

        _fundVault(4000e6);
        borrowViaMulticall(4000e6);
        vm.roll(BLOCK_START + 2);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, _tokenId);
        data[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 3000e6);

        vm.expectRevert(bytes("Debt exceeds max loan"));
        _multicallBatch(data);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 4000e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 7500e18);
    }

    function test_churnCollateral_sameMulticall_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId2);
        data[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, uint256(6e9));
        data[2] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, _tokenId2);

        vm.expectRevert(bytes("Debt exceeds max loan"));
        _multicallBatch(data);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_mergeIntoCollateral_borrowAgainstInflated() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        uint256 externalTokenId = _mockVe.mintTo(_user, int128(uint128(3000e18)));

        vm.startPrank(_user);
        IVotingEscrow(_ve).approve(_portfolioAccount, externalTokenId);
        VotingEscrowFacet(_portfolioAccount).merge(externalTokenId, _tokenId);
        vm.stopPrank();
        vm.roll(BLOCK_START + 2);

        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 8000e18);
        (, uint256 newMax) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(newMax, 8e9);

        _fundVault(7e9);
        borrowViaMulticall(7e9);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 7e9);
        assertLe(CollateralFacet(_portfolioAccount).getTotalDebt(), newMax);
    }

    // --- Cross-path combinations ---

    function test_payThenBorrow_sameBlock_cannotExceedOriginalMax() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);
        vm.roll(BLOCK_START + 2);

        payViaLendingFacet(_portfolioAccount, 1000e6);
        borrowViaMulticall(1000e6);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY);

        vm.expectRevert();
        borrowViaMulticall(1);
    }

    function test_processRewards_thenBorrow_sameBlock() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);
        vm.roll(BLOCK_START + 2);

        uint256 rewardsPayment = 500e6;
        payViaLendingFacet(_portfolioAccount, rewardsPayment);

        borrowViaMulticall(rewardsPayment);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY);

        vm.expectRevert();
        borrowViaMulticall(1);
    }

    function test_borrowPayBorrow_cannotExceedMax() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 3);

        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);
        payViaLendingFacet(_portfolioAccount, MAX_LOAN_IGNORE_SUPPLY);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);

        vm.expectRevert(abi.encodeWithSelector(CollateralManager.BadDebt.selector, 1));
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY + 1);
    }

    function test_vaultDepositDoesNotIncreaseCollateralLimit() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);
        vm.roll(BLOCK_START + 2);

        address vault = ILoan(_portfolioFactoryConfig.getLoanContract())._vault();
        deal(address(_asset), vault, IERC20(address(_asset)).balanceOf(vault) + 1000e9);

        vm.expectRevert();
        borrowViaMulticall(1);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY);
    }

    function test_vaultDepleted_cannotBorrowMore() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(2000e6);
        borrowViaMulticall(2000e6);
        vm.roll(BLOCK_START + 2);

        address vault = ILoan(_portfolioFactoryConfig.getLoanContract())._vault();
        uint256 vaultBalance = IERC20(address(_asset)).balanceOf(vault);
        if (vaultBalance > 1) {
            deal(address(_asset), vault, 1);
        }

        (uint256 maxLoan,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        if (maxLoan == 0) {
            vm.expectRevert();
            borrowViaMulticall(1);
        }

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 2000e6);
    }

    // --- Config changes ---

    function test_borrowWithZeroRewardsRate_reverts() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        vm.prank(_owner);
        _loanConfig.setRewardsRate(0);

        _fundVault(1000e6);

        vm.expectRevert(abi.encodeWithSelector(CollateralManager.BadDebt.selector, 1));
        borrowViaMulticall(1);
    }

    function test_rewardsRateSetToZero_accountNotBricked() public {
        addCollateralViaMulticall(_tokenId);
        _fundVault(BORROW_AMOUNT);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(BORROW_AMOUNT);

        vm.roll(BLOCK_START + 2);
        vm.prank(_owner);
        _loanConfig.setRewardsRate(0);

        vm.roll(BLOCK_START + 3);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, false);
        _multicallBatch(data);
    }

    function test_rewardsRateSetToZero_canStillPay() public {
        addCollateralViaMulticall(_tokenId);
        _fundVault(BORROW_AMOUNT);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(BORROW_AMOUNT);

        vm.roll(BLOCK_START + 2);
        vm.prank(_owner);
        _loanConfig.setRewardsRate(0);

        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        vm.roll(BLOCK_START + 3);

        payViaLendingFacet(_portfolioAccount, 1000e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), debtBefore - 1000e6);
    }

    function test_multiplierSetToZero_accountNotBricked() public {
        addCollateralViaMulticall(_tokenId);
        _fundVault(BORROW_AMOUNT);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(BORROW_AMOUNT);

        vm.roll(BLOCK_START + 2);
        vm.prank(_owner);
        _loanConfig.setMultiplier(0);

        vm.roll(BLOCK_START + 3);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, false);
        _multicallBatch(data);
    }

    function test_borrowMaxThenRateDrops_underwaterButNotBricked() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);
        borrowViaMulticall(MAX_LOAN_IGNORE_SUPPLY);
        vm.roll(BLOCK_START + 2);

        vm.prank(_owner);
        _loanConfig.setRewardsRate(5000);

        (, uint256 newMax) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(newMax, 2500e6);
        assertGt(CollateralFacet(_portfolioAccount).getTotalDebt(), newMax);

        vm.roll(BLOCK_START + 3);
        payViaLendingFacet(_portfolioAccount, 1000e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), MAX_LOAN_IGNORE_SUPPLY - 1000e6);

        vm.roll(BLOCK_START + 4);
        bytes[] memory voteData = new bytes[](1);
        voteData[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, false);
        _multicallBatch(voteData);

        vm.roll(BLOCK_START + 5);
        vm.expectRevert();
        borrowViaMulticall(1);
    }

    function test_rateDecrease_thenRecovery() public {
        addCollateralViaMulticall(_tokenId);
        _fundVault(BORROW_AMOUNT);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(BORROW_AMOUNT);

        vm.roll(BLOCK_START + 2);
        _makeUnderwater();

        vm.roll(BLOCK_START + 3);
        payViaLendingFacet(_portfolioAccount, CollateralFacet(_portfolioAccount).getTotalDebt());
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);

        vm.startPrank(_owner);
        _loanConfig.setRewardsRate(2);
        _loanConfig.setRewardsRate(4);
        _loanConfig.setRewardsRate(8);
        _loanConfig.setRewardsRate(16);
        _loanConfig.setRewardsRate(32);
        _loanConfig.setRewardsRate(64);
        _loanConfig.setRewardsRate(128);
        _loanConfig.setRewardsRate(256);
        _loanConfig.setRewardsRate(512);
        _loanConfig.setRewardsRate(1024);
        _loanConfig.setRewardsRate(2048);
        _loanConfig.setRewardsRate(4096);
        _loanConfig.setRewardsRate(8192);
        _loanConfig.setRewardsRate(10000);
        vm.stopPrank();

        vm.roll(BLOCK_START + 4);
        _fundVault(500e6);
        borrowViaMulticall(500e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 500e6);
    }

    function test_rateIncrease_thenBorrow() public {
        addCollateralViaMulticall(_tokenId);
        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 3);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(4500e6);

        vm.roll(BLOCK_START + 2);
        vm.prank(_owner);
        _loanConfig.setRewardsRate(20000);

        (, uint256 newMax) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(newMax, 10e9);

        vm.roll(BLOCK_START + 3);
        borrowViaMulticall(2000e6);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 6500e6);
        assertLt(CollateralFacet(_portfolioAccount).getTotalDebt(), newMax);
    }

    // --- Edge cases ---

    function test_payMoreThanDebt_refundsExcess() public {
        addCollateralViaMulticall(_tokenId);
        _fundVault(1000e6);
        vm.roll(BLOCK_START + 1);
        borrowViaMulticall(1000e6);

        vm.roll(BLOCK_START + 2);

        uint256 overpayAmount = 2000e6;
        deal(address(_asset), _user, overpayAmount);
        uint256 userBalBefore = IERC20(address(_asset)).balanceOf(_user);

        vm.startPrank(_user);
        IERC20(address(_asset)).approve(_portfolioAccount, overpayAmount);
        uint256 excess = LendingFacet(_portfolioAccount).pay(overpayAmount);
        vm.stopPrank();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(excess, overpayAmount - 1000e6);
        assertEq(IERC20(address(_asset)).balanceOf(_user), userBalBefore - 1000e6);
    }

    function test_borrowThenAddCollateral_sameMulticall() public {
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();

        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        _fundVault(MAX_LOAN_IGNORE_SUPPLY * 2);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 4800e6);
        data[1] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId2);
        _multicallBatch(data);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 4800e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 7500e18);
    }

    function test_underwaterAccount_addCollateralAndBorrow_netMustImprove() public {
        _setupUnderwaterAccount();

        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();

        vm.roll(BLOCK_START + 3);
        _fundVault(500e6);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId2);
        data[1] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 500000);

        vm.expectRevert(); // BadDebt or UndercollateralizedDebt — enforcement rejects the overborrow
        _multicallBatch(data);
    }

    function test_zeroDebt_canAddAndRemoveCollateralFreely() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);
        removeCollateralViaMulticall(_tokenId);

        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
    }

    function test_overSuppliedVaultDebt_atomicRevert() public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        address loanContract = _portfolioFactoryConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_asset), vault, 1000e6);

        borrowViaMulticall(700e6);
        vm.roll(BLOCK_START + 2);

        (uint256 remainingMaxLoan,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 excessBorrow = remainingMaxLoan + 100e6;
        uint256 currentVaultBal = IERC20(address(_asset)).balanceOf(vault);
        if (currentVaultBal < excessBorrow) {
            deal(address(_asset), vault, currentVaultBal + excessBorrow);
        }

        vm.expectRevert(abi.encodeWithSelector(CollateralManager.BadDebt.selector, 100e6));
        borrowViaMulticall(excessBorrow);

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 700e6);

        vm.roll(BLOCK_START + 3);
        assertTrue(CollateralFacet(_portfolioAccount).enforceCollateralRequirements());
    }

    // --- Fuzz ---

    function testFuzz_borrowRandomAmount(uint256 amount) public {
        addCollateralViaMulticall(_tokenId);
        vm.roll(BLOCK_START + 1);

        amount = bound(amount, 1, MAX_LOAN_IGNORE_SUPPLY * 2);
        _fundVault(amount * 2);

        if (amount <= MAX_LOAN_IGNORE_SUPPLY) {
            borrowViaMulticall(amount);
            uint256 debt = CollateralFacet(_portfolioAccount).getTotalDebt();
            assertEq(debt, amount);
            assertLe(debt, MAX_LOAN_IGNORE_SUPPLY);
        } else {
            vm.expectRevert();
            borrowViaMulticall(amount);
            assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        }
    }
}
