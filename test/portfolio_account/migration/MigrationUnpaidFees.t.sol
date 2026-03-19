// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {MockVotingEscrow} from "../../mocks/MockVotingEscrow.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";

/**
 * @title MigrationUnpaidFeesTest
 * @notice Tests that LoanV2.migrateToPortfolio() rejects migration when unpaid fees exist.
 *
 * ISSUE UNDER TEST:
 * A new require was added to LoanV2.migrateToPortfolio():
 *     require(loan.unpaidFees == 0);
 * And in MigrationFacet.migrate():
 *     require(unpaidFees == 0);
 *
 * These guards prevent users from migrating loans to portfolio accounts while
 * still owing protocol fees, which would otherwise cause fee accounting to be lost.
 */
contract MigrationUnpaidFeesTest is LocalSetup {
    // Storage slot constants for LoanV2 (behind UUPS proxy)
    // ReentrancyGuard._status = slot 0
    // _voter = slot 1, _rewardsDistributor = slot 2, _pool = slot 3
    // _asset = slot 4, _aero = slot 5, _ve = slot 6
    // _aeroRouter = slot 7, _aeroFactory = slot 8, _rateCalculator = slot 9
    // _vault = slot 10, _paused = slot 11, _outstandingCapital = slot 12
    // _multiplier = slot 13, _loanDetails = slot 14
    uint256 constant VE_SLOT = 6;
    uint256 constant VOTER_SLOT = 1;
    uint256 constant LOAN_DETAILS_SLOT = 13;  // discovered via test_discoverStorageSlot
    uint256 constant UNPAID_FEES_OFFSET = 10;

    // Test token IDs (separate from _tokenId which is already in portfolio)
    uint256 migrationTokenId;
    uint256 migrationTokenId2;

    function setUp() public override {
        super.setUp();

        // Override _ve and _voter in the loan proxy to point to our mocks.
        // The Loan.initialize() hardcodes mainnet addresses for _ve and _voter,
        // so we must patch these in the proxy's storage to use our local mocks.
        vm.store(_loanContract, bytes32(VE_SLOT), bytes32(uint256(uint160(address(_mockVe)))));
        vm.store(_loanContract, bytes32(VOTER_SLOT), bytes32(uint256(uint160(address(_mockVoter)))));

        // Mint veNFTs for migration tests (owned by _user)
        migrationTokenId = _mockVe.mintTo(_user, int128(uint128(5000e18)));
        migrationTokenId2 = _mockVe.mintTo(_user, int128(uint128(5000e18)));

        // Fund the vault with USDC so borrowing works
        _mockUsdc.mint(_vault, 1_000_000e6);
    }

    // ─── Helper: compute storage slot for _loanDetails[tokenId].unpaidFees ───

    function _unpaidFeesSlot(uint256 tokenId) internal pure returns (bytes32) {
        bytes32 baseSlot = keccak256(abi.encode(tokenId, LOAN_DETAILS_SLOT));
        return bytes32(uint256(baseSlot) + UNPAID_FEES_OFFSET);
    }

    // ─── Helper: read unpaidFees from the public getter ───

    function _getUnpaidFees(uint256 tokenId) internal view returns (uint256) {
        // The auto-generated getter for mapping(uint256 => LoanInfo) public _loanDetails
        // returns all value-type fields. unpaidFees is the 10th value-type field.
        // Fields: tokenId, balance, borrower, timestamp, outstandingCapital,
        //         zeroBalanceOption, voteTimestamp, claimTimestamp, weight,
        //         unpaidFees, preferredToken, increasePercentage, topUp, optInCommunityRewards
        (,,,,,,,,,uint256 unpaidFees,,,,) = LoanV2(_loanContract)._loanDetails(tokenId);
        return unpaidFees;
    }

    // ─── Helper: create a loan for _user with no borrowing ───

    function _createLoanForUser(uint256 tokenId) internal {
        vm.startPrank(_user);
        // User must approve the loan contract to transfer the veNFT
        _mockVe.approve(_loanContract, tokenId);
        LoanV2(_loanContract).requestLoan(
            tokenId,
            0, // amount = 0, no borrowing
            LoanV2.ZeroBalanceOption.DoNothing,
            0, // increasePercentage
            address(0), // preferredToken
            false, // topUp
            false  // optInCommunityRewards
        );
        vm.stopPrank();
    }

    // ─── Helper: set unpaidFees for a loan via vm.store ───

    function _setUnpaidFees(uint256 tokenId, uint256 fees) internal {
        vm.store(_loanContract, _unpaidFeesSlot(tokenId), bytes32(fees));
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test 1: Migration REVERTS when unpaidFees > 0
    // ══════════════════════════════════════════════════════════════════════

    function test_migrateWithUnpaidFees_reverts() public {
        // Create a loan with no borrowing (unpaidFees starts at 0)
        _createLoanForUser(migrationTokenId);

        // Verify loan was created
        (, address borrower) = LoanV2(_loanContract).getLoanDetails(migrationTokenId);
        assertEq(borrower, _user, "borrower should be _user");

        // Set unpaidFees to a non-zero value via vm.store
        _setUnpaidFees(migrationTokenId, 30e6);

        // Verify the unpaidFees was actually set
        uint256 fees = _getUnpaidFees(migrationTokenId);
        assertEq(fees, 30e6, "unpaidFees should be 30 USDC after vm.store");

        // Attempt migration - should revert because unpaidFees > 0
        vm.prank(_user);
        vm.expectRevert();
        LoanV2(_loanContract).migrateToPortfolio(migrationTokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test 2: Migration SUCCEEDS when unpaidFees == 0
    // ══════════════════════════════════════════════════════════════════════

    function test_migrateWithZeroUnpaidFees_succeeds() public {
        // Create a loan with no borrowing (unpaidFees == 0)
        _createLoanForUser(migrationTokenId2);

        // Verify unpaidFees is 0
        uint256 fees = _getUnpaidFees(migrationTokenId2);
        assertEq(fees, 0, "unpaidFees should be 0 for a fresh loan with no borrowing");

        // Verify the veNFT is currently held by the loan contract
        assertEq(_mockVe.ownerOf(migrationTokenId2), _loanContract, "veNFT should be in loan contract");

        // Migrate - should succeed
        vm.prank(_user);
        LoanV2(_loanContract).migrateToPortfolio(migrationTokenId2);

        // After migration: veNFT should be in the portfolio account
        assertEq(
            _mockVe.ownerOf(migrationTokenId2),
            _portfolioAccount,
            "veNFT should be transferred to portfolio account after migration"
        );

        // After migration: loan details should be deleted
        (uint256 balance, address borrower) = LoanV2(_loanContract).getLoanDetails(migrationTokenId2);
        assertEq(borrower, address(0), "borrower should be zero after loan deletion");
        assertEq(balance, 0, "balance should be zero after loan deletion");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test 3: Migration reverts with even 1 wei of unpaid fees
    // ══════════════════════════════════════════════════════════════════════

    function test_migrateWithMinimalUnpaidFees_reverts() public {
        _createLoanForUser(migrationTokenId);

        // Set unpaidFees to 1 (smallest possible non-zero value)
        _setUnpaidFees(migrationTokenId, 1);
        assertEq(_getUnpaidFees(migrationTokenId), 1, "unpaidFees should be 1");

        vm.prank(_user);
        vm.expectRevert();
        LoanV2(_loanContract).migrateToPortfolio(migrationTokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test 4: Non-borrower cannot call migrateToPortfolio
    // ══════════════════════════════════════════════════════════════════════

    function test_migrateByNonBorrower_reverts() public {
        _createLoanForUser(migrationTokenId);

        // A random address tries to migrate - should revert because borrower != msg.sender
        // (enforced in PortfolioLoanLib.migrateToPortfolio: require(borrower == msg.sender))
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert();
        LoanV2(_loanContract).migrateToPortfolio(migrationTokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test 5: Fuzz - any non-zero unpaidFees blocks migration
    // ══════════════════════════════════════════════════════════════════════

    function testFuzz_migrateWithNonZeroUnpaidFees_reverts(uint256 fees) public {
        fees = bound(fees, 1, type(uint128).max);

        _createLoanForUser(migrationTokenId);
        _setUnpaidFees(migrationTokenId, fees);

        vm.prank(_user);
        vm.expectRevert();
        LoanV2(_loanContract).migrateToPortfolio(migrationTokenId);
    }
}
