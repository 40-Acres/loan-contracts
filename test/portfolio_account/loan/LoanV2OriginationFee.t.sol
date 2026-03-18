// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {MockVotingEscrow} from "../../mocks/MockVotingEscrow.sol";

/**
 * @title LoanV2OriginationFeeTest
 * @notice Tests for LoanV2 changes to origination fee handling and unpaid fees payment.
 *
 * CHANGES UNDER TEST:
 *
 * 1. _increaseLoan: Origination fee (0.8%) is now taken upfront from vault and sent
 *    to owner(). Borrower receives amount - fee. Loan balance = amount (no fee added).
 *    unpaidFees is NOT set.
 *
 * 2. _pay: Unpaid fees cap changed from 25% of payment to 100% of payment.
 *    This means fees from legacy loans clear faster.
 */
contract LoanV2OriginationFeeTest is LocalSetup {
    // Storage slot constants (same as MigrationUnpaidFees test)
    uint256 constant VE_SLOT = 6;
    uint256 constant VOTER_SLOT = 1;
    uint256 constant LOAN_DETAILS_SLOT = 13;
    uint256 constant UNPAID_FEES_OFFSET = 10;

    // Chainlink oracle address hardcoded in LoanV2.confirmUsdcPrice()
    address constant CHAINLINK_USDC_ORACLE = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    uint256 loanTokenId;

    function setUp() public override {
        super.setUp();

        // Patch _ve and _voter in the loan proxy to use our mocks
        vm.store(_loanContract, bytes32(VE_SLOT), bytes32(uint256(uint160(address(_mockVe)))));
        vm.store(_loanContract, bytes32(VOTER_SLOT), bytes32(uint256(uint160(address(_mockVoter)))));

        // Set rewardsRate and multiplier on the loan contract so getMaxLoan returns meaningful values
        // rewardsRate=10000, multiplier=100 => maxLoanIgnoreSupply = (5000e18 * 10000 / 1e6) * 100 / 1e12 = 5000e6
        vm.startPrank(_owner);
        LoanV2(_loanContract).setRewardsRate(10000);
        LoanV2(_loanContract).setMultiplier(100);
        vm.stopPrank();

        // Mock the Chainlink USDC/USD oracle so confirmUsdcPrice() passes
        // latestRoundData() returns (uint80, int256, uint256, uint256, uint80)
        // We need: answer >= 99900000, timestamp > block.timestamp - 25 hours
        vm.mockCall(
            CHAINLINK_USDC_ORACLE,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(100000000), uint256(0), block.timestamp, uint80(1))
        );

        // Mint a veNFT for loan testing (5000e18 AERO locked, permanent)
        loanTokenId = _mockVe.mintTo(_user, int128(uint128(5000e18)));

        // Fund the vault with USDC
        _mockUsdc.mint(_vault, 1_000_000e6);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _unpaidFeesSlot(uint256 tokenId) internal pure returns (bytes32) {
        bytes32 baseSlot = keccak256(abi.encode(tokenId, LOAN_DETAILS_SLOT));
        return bytes32(uint256(baseSlot) + UNPAID_FEES_OFFSET);
    }

    function _balanceSlot(uint256 tokenId) internal pure returns (bytes32) {
        // balance is at offset 1 in LoanInfo struct (tokenId=0, balance=1)
        bytes32 baseSlot = keccak256(abi.encode(tokenId, LOAN_DETAILS_SLOT));
        return bytes32(uint256(baseSlot) + 1);
    }

    function _getUnpaidFees(uint256 tokenId) internal view returns (uint256) {
        (,,,,,,,,,uint256 unpaidFees,,,,) = LoanV2(_loanContract)._loanDetails(tokenId);
        return unpaidFees;
    }

    function _getLoanBalance(uint256 tokenId) internal view returns (uint256) {
        (uint256 balance,) = LoanV2(_loanContract).getLoanDetails(tokenId);
        return balance;
    }

    /// @dev Creates a loan with a specific borrow amount
    function _createLoanWithBorrow(uint256 tokenId, uint256 amount) internal {
        vm.startPrank(_user);
        _mockVe.approve(_loanContract, tokenId);
        LoanV2(_loanContract).requestLoan(
            tokenId,
            amount,
            LoanV2.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();
    }

    /// @dev Creates a loan with no borrowing
    function _createLoanNoBorrow(uint256 tokenId) internal {
        _createLoanWithBorrow(tokenId, 0);
    }

    /// @dev Sets unpaidFees for a token via vm.store (simulates legacy loan state)
    function _setUnpaidFees(uint256 tokenId, uint256 fees) internal {
        vm.store(_loanContract, _unpaidFeesSlot(tokenId), bytes32(fees));
    }

    /// @dev Increases loan balance via vm.store (to simulate legacy fees being added to balance)
    function _addToBalance(uint256 tokenId, uint256 extra) internal {
        bytes32 slot = _balanceSlot(tokenId);
        uint256 current = uint256(vm.load(_loanContract, slot));
        vm.store(_loanContract, slot, bytes32(current + extra));
    }

    // ══════════════════════════════════════════════════════════════════════
    // ORIGINATION FEE TESTS
    // ══════════════════════════════════════════════════════════════════════

    function test_originationFeeGoesToOwner() public {
        uint256 borrowAmount = 100e6; // 100 USDC
        uint256 expectedFee = (borrowAmount * 80) / 10000; // 0.8% = 0.8 USDC

        uint256 ownerBalanceBefore = _mockUsdc.balanceOf(_owner);

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        uint256 ownerBalanceAfter = _mockUsdc.balanceOf(_owner);
        assertEq(
            ownerBalanceAfter - ownerBalanceBefore,
            expectedFee,
            "Owner should receive the origination fee"
        );
    }

    function test_borrowerReceivesNetAmount() public {
        uint256 borrowAmount = 100e6;
        uint256 expectedFee = (borrowAmount * 80) / 10000;
        uint256 expectedNet = borrowAmount - expectedFee;

        uint256 userBalanceBefore = _mockUsdc.balanceOf(_user);

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        uint256 userBalanceAfter = _mockUsdc.balanceOf(_user);
        assertEq(
            userBalanceAfter - userBalanceBefore,
            expectedNet,
            "Borrower should receive amount minus origination fee"
        );
    }

    function test_loanBalanceEqualsAmount() public {
        uint256 borrowAmount = 100e6;

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        uint256 balance = _getLoanBalance(loanTokenId);
        assertEq(balance, borrowAmount, "Loan balance should equal the borrow amount (no fee added)");
    }

    function test_unpaidFeesStaysZeroOnBorrow() public {
        uint256 borrowAmount = 100e6;

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        uint256 unpaidFees = _getUnpaidFees(loanTokenId);
        assertEq(unpaidFees, 0, "unpaidFees should remain 0 after borrowing");
    }

    function test_vaultBalanceDecreasedByFullAmount() public {
        uint256 borrowAmount = 100e6;

        uint256 vaultBalanceBefore = _mockUsdc.balanceOf(_vault);

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        uint256 vaultBalanceAfter = _mockUsdc.balanceOf(_vault);
        assertEq(
            vaultBalanceBefore - vaultBalanceAfter,
            borrowAmount,
            "Vault should lose the full borrow amount (fee + net go to different recipients)"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // UNPAID FEES PAYMENT TESTS (legacy loans with unpaidFees > 0)
    // ══════════════════════════════════════════════════════════════════════

    function test_payFullyClearsUnpaidFees() public {
        uint256 borrowAmount = 100e6;
        uint256 feeAmount = 10e6; // Simulate 10 USDC unpaid fees from old system

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        // Simulate legacy state: set unpaidFees and increase balance accordingly
        _setUnpaidFees(loanTokenId, feeAmount);
        _addToBalance(loanTokenId, feeAmount);

        // Fund user to make payment
        _mockUsdc.mint(_user, 200e6);
        vm.startPrank(_user);
        _mockUsdc.approve(_loanContract, 200e6);
        // Pay more than the fees so they should be fully cleared
        LoanV2(_loanContract).pay(loanTokenId, 50e6);
        vm.stopPrank();

        uint256 feesAfter = _getUnpaidFees(loanTokenId);
        assertEq(feesAfter, 0, "unpaidFees should be fully cleared when payment >= fees");
    }

    function test_payPartialUnpaidFees() public {
        uint256 borrowAmount = 100e6;
        uint256 feeAmount = 20e6; // 20 USDC unpaid fees

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        // Simulate legacy state
        _setUnpaidFees(loanTokenId, feeAmount);
        _addToBalance(loanTokenId, feeAmount);

        // Fund user with small payment (less than fees)
        uint256 paymentAmount = 8e6; // 8 USDC < 20 USDC fees
        _mockUsdc.mint(_user, paymentAmount);
        vm.startPrank(_user);
        _mockUsdc.approve(_loanContract, paymentAmount);
        LoanV2(_loanContract).pay(loanTokenId, paymentAmount);
        vm.stopPrank();

        // Under the NEW code (no 25% cap), all 8 USDC should go to fees
        // Under the OLD code with 25% cap, only 25% of 8 = 2 USDC would go to fees
        uint256 feesAfter = _getUnpaidFees(loanTokenId);
        assertEq(
            feesAfter,
            feeAmount - paymentAmount,
            "Full payment amount should reduce unpaid fees (no 25% cap)"
        );
    }

    function test_payUnpaidFeesGoesToOwner() public {
        uint256 borrowAmount = 100e6;
        uint256 feeAmount = 10e6;

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        _setUnpaidFees(loanTokenId, feeAmount);
        _addToBalance(loanTokenId, feeAmount);

        _mockUsdc.mint(_user, 50e6);
        uint256 ownerBalanceBefore = _mockUsdc.balanceOf(_owner);

        vm.startPrank(_user);
        _mockUsdc.approve(_loanContract, 50e6);
        LoanV2(_loanContract).pay(loanTokenId, 50e6);
        vm.stopPrank();

        uint256 ownerBalanceAfter = _mockUsdc.balanceOf(_owner);
        assertEq(
            ownerBalanceAfter - ownerBalanceBefore,
            feeAmount,
            "Owner should receive the full unpaid fees amount"
        );
    }

    function test_payUnpaidFeesThenDebt() public {
        uint256 borrowAmount = 100e6;
        uint256 feeAmount = 10e6;

        _createLoanWithBorrow(loanTokenId, borrowAmount);

        _setUnpaidFees(loanTokenId, feeAmount);
        _addToBalance(loanTokenId, feeAmount);

        // Balance is now 100e6 + 10e6 = 110e6
        uint256 balanceBefore = _getLoanBalance(loanTokenId);
        assertEq(balanceBefore, borrowAmount + feeAmount, "Pre-condition: balance should include fees");

        // Pay 30 USDC: 10 goes to fees, 20 goes to debt reduction
        uint256 paymentAmount = 30e6;
        _mockUsdc.mint(_user, paymentAmount);
        vm.startPrank(_user);
        _mockUsdc.approve(_loanContract, paymentAmount);
        LoanV2(_loanContract).pay(loanTokenId, paymentAmount);
        vm.stopPrank();

        uint256 balanceAfter = _getLoanBalance(loanTokenId);
        // Balance should decrease by the full payment: 110 - 30 = 80
        assertEq(
            balanceAfter,
            balanceBefore - paymentAmount,
            "Loan balance should decrease by full payment (fees + debt)"
        );

        uint256 feesAfter = _getUnpaidFees(loanTokenId);
        assertEq(feesAfter, 0, "Fees should be fully cleared");
    }
}
