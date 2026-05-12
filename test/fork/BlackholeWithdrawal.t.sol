// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console } from "forge-std/Test.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { BlackholeLoanV2 as Loan } from "../../src/Blackhole/BlackholeLoanV2.sol";

/**
 * @title BlackholeWithdrawalDebtTest
 * @notice Verifies that on the live BlackholeLoanV2 proxy, with rewardsRate forced to 0,
 *         a veNFT with outstanding debt CANNOT be withdrawn via claimCollateral.
 *         Pinned to Avalanche block 76178925.
 */
contract BlackholeWithdrawalDebtTest is Test {
    address constant LOAN = 0x5122f5154DF20E5F29df53E633cE1ac5b6623558;
    address constant VE = 0xEac562811cc6abDbB2c9EE88719eCA4eE79Ad763;
    address constant VOTER = 0xE30D0C8532721551a51a9FeC7FB233759964d9e3;

    function setUp() public {
        vm.createSelectFork(vm.envString("AVAX_RPC_URL"), 76178925);

        // Deploy a fresh implementation and upgrade the live proxy in place.
        Loan loanImpl = new Loan();
        address loanOwner = Loan(LOAN).owner();
        vm.startPrank(loanOwner);
        Loan(LOAN).upgradeToAndCall(address(loanImpl), new bytes(0));
        // Freeze rewards so no rewards-rate-dependent paths are exercised.
        Loan(LOAN).setRewardsRate(0);
        vm.stopPrank();
    }

    function test_ClaimCollateral_RevertsWhenDebtOutstanding() public {
        uint256 tokenId = 26783;
        address expectedBorrower = 0x3854115874e5caa176Cc8c3cBCd5383C35dF83A4;

        // _loanDetails public getter tuple (skips dynamic arrays):
        // tokenId, balance, borrower, timestamp, outstandingCapital, zeroBalanceOption,
        // voteTimestamp, claimTimestamp, weight, unpaidFees, preferredToken,
        // increasePercentage, topUp, optInCommunityRewards
        (, uint256 balance, address borrower,,,,,,,,,,,) = Loan(LOAN)._loanDetails(tokenId);
        console.log("Token:", tokenId);
        console.log("Borrower:", borrower);
        console.log("Balance:", balance);

        assertEq(borrower, expectedBorrower, "borrower mismatch");
        assertGt(balance, 0, "expected outstanding debt > 0");

        // Pre-state: NFT custodied by Loan contract.
        assertEq(IERC721(VE).ownerOf(tokenId), LOAN, "ve must be custodied by LOAN pre-call");

        // Borrower calls claimCollateral while balance > 0 → must revert.
        vm.prank(borrower);
        vm.expectRevert();
        Loan(LOAN).claimCollateral(tokenId);

        // Post-state: NFT still custodied by Loan contract.
        assertEq(IERC721(VE).ownerOf(tokenId), LOAN, "ve must remain custodied by LOAN");
    }

    /**
     * @notice Proves that LoanV2.claimCollateral's `require(balance == 0)` is the true guard
     *         preventing collateral withdrawal under outstanding debt — independent of any
     *         vote/attachment (ATT) check on the underlying veNFT.
     *
     *         To isolate the debt guard, we forcibly reset the active vote at the voter level
     *         (bypassing BlackholeLoanV2.reset, which itself requires balance == 0) by pranking
     *         as the LOAN contract — which owns the NFT and is therefore approved/owner per the
     *         voter's access control. We then attempt claimCollateral and verify it STILL reverts
     *         on the debt check.
     */
    function test_ClaimCollateral_StillReverts_WhenVoteForciblyReset() public {
        uint256 tokenId = 26783;
        address expectedBorrower = 0x3854115874e5caa176Cc8c3cBCd5383C35dF83A4;

        // Step 1: sanity — confirm outstanding debt and borrower identity.
        (, uint256 balance, address borrower,,,,,,,,,,,) = Loan(LOAN)._loanDetails(tokenId);
        assertEq(borrower, expectedBorrower, "borrower mismatch");
        assertGt(balance, 0, "expected outstanding debt > 0");
        assertEq(IERC721(VE).ownerOf(tokenId), LOAN, "ve must be custodied by LOAN pre-call");

        // Step 2: forcibly reset the vote at the voter level by pranking as LOAN (the NFT owner).
        // This bypasses BlackholeLoanV2.reset, which would itself revert on its own
        // require(loan.balance == 0). We want to remove the ATT guard from the equation entirely.
        vm.prank(LOAN);
        IVoter(VOTER).reset(tokenId);

        // Step 4: with the vote forcibly cleared, claimCollateral must STILL revert because
        // loan.balance > 0. This proves the debt guard is independent of the ATT guard.
        vm.prank(borrower);
        vm.expectRevert();
        Loan(LOAN).claimCollateral(tokenId);

        // Step 5: NFT still custodied by Loan contract — no exfiltration.
        assertEq(IERC721(VE).ownerOf(tokenId), LOAN, "ve must remain custodied by LOAN post-call");

        // Debt record must remain intact (claimCollateral did not delete _loanDetails).
        (, uint256 balanceAfter, address borrowerAfter,,,,,,,,,,,) = Loan(LOAN)._loanDetails(tokenId);
        assertEq(balanceAfter, balance, "loan balance must be unchanged after failed claim");
        assertEq(borrowerAfter, borrower, "loan borrower must be unchanged after failed claim");
    }
}

/**
 * @title BlackholeWithdrawalNoDebtTest
 * @notice Verifies that with rewardsRate = 0, veNFTs with balance == 0 can be withdrawn
 *         cleanly via claimCollateral. Pinned to Avalanche block 84934734.
 */
contract BlackholeWithdrawalNoDebtTest is Test {
    address constant LOAN = 0x5122f5154DF20E5F29df53E633cE1ac5b6623558;
    address constant VE = 0xEac562811cc6abDbB2c9EE88719eCA4eE79Ad763;

    function setUp() public {
        vm.createSelectFork(vm.envString("AVAX_RPC_URL"), 84934734);

        Loan loanImpl = new Loan();
        address loanOwner = Loan(LOAN).owner();
        vm.startPrank(loanOwner);
        Loan(LOAN).upgradeToAndCall(address(loanImpl), new bytes(0));
        Loan(LOAN).setRewardsRate(0);
        vm.stopPrank();
    }

    function _claimAndAssert(uint256 tokenId, address expectedBorrower) internal {
        (, uint256 balance, address borrower,,,,,,,,,,,) = Loan(LOAN)._loanDetails(tokenId);
        console.log("Token:", tokenId);
        console.log("Borrower:", borrower);
        console.log("Balance:", balance);

        assertEq(borrower, expectedBorrower, "borrower mismatch");
        assertEq(balance, 0, "expected zero debt");

        // Pre-state: NFT custodied by Loan.
        assertEq(IERC721(VE).ownerOf(tokenId), LOAN, "ve must be custodied by LOAN pre-claim");

        // Borrower must reset their active vote before the underlying ve can be transferred.
        vm.prank(borrower);
        Loan(LOAN).reset(tokenId);

        // Borrower withdraws.
        vm.prank(borrower);
        Loan(LOAN).claimCollateral(tokenId);

        // Post-state: NFT transferred to borrower.
        assertEq(IERC721(VE).ownerOf(tokenId), borrower, "ve must be transferred to borrower");

        // Loan record cleared.
        (, uint256 balanceAfter, address borrowerAfter,,,,,,,,,,,) = Loan(LOAN)._loanDetails(tokenId);
        assertEq(balanceAfter, 0, "loan balance must be zero after claim");
        assertEq(borrowerAfter, address(0), "loan borrower must be cleared after claim");
    }

    function test_ClaimCollateral_Succeeds_Token34401() public {
        _claimAndAssert(34401, 0xC5098016892850499613e258feF302bd69aC487b);
    }

    function test_ClaimCollateral_Succeeds_Token21565() public {
        _claimAndAssert(21565, 0x3C5C8535eBE4B544A3a22a2Ff9b7b2b2403e8d83);
    }

    function test_ClaimCollateral_Succeeds_Token6990() public {
        _claimAndAssert(6990, 0xd5b2DaF2285d0FBf2F1c2A20E2866ccf9617E83B);
    }
}
