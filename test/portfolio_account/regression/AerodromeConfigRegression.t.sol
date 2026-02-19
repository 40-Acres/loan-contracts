// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

/**
 * @title AerodromeConfigRegression
 * @dev Tests that configuration values, ownership, and external addresses
 *      are correct after deployment.
 */
contract AerodromeConfigRegression is BaseDeploymentSetup {
    // ─── LoanConfig values ───────────────────────────────────────────

    function testRewardsRate() public view {
        assertEq(loanConfig.getRewardsRate(), 10000, "rewardsRate should be 10000");
    }

    function testMultiplier() public view {
        assertEq(loanConfig.getMultiplier(), 100, "multiplier should be 100");
    }

    function testLenderPremium() public view {
        assertEq(loanConfig.getLenderPremium(), 2000, "lenderPremium should be 2000");
    }

    function testTreasuryFee() public view {
        assertEq(loanConfig.getTreasuryFee(), 500, "treasuryFee should be 500");
    }

    function testZeroBalanceFee() public view {
        assertEq(loanConfig.getZeroBalanceFee(), 100, "zeroBalanceFee should be 100");
    }

    // ─── Config ownership ────────────────────────────────────────────

    function testPortfolioAccountConfigOwnership() public view {
        assertEq(portfolioAccountConfig.owner(), DEPLOYER, "PortfolioAccountConfig owner should be DEPLOYER");
    }

    function testVotingConfigOwnership() public view {
        assertEq(votingConfig.owner(), DEPLOYER, "VotingConfig owner should be DEPLOYER");
    }

    function testLoanConfigOwnership() public view {
        assertEq(loanConfig.owner(), DEPLOYER, "LoanConfig owner should be DEPLOYER");
    }

    function testSwapConfigOwnership() public view {
        assertEq(swapConfig.owner(), DEPLOYER, "SwapConfig owner should be DEPLOYER");
    }

    // ─── Config cross-references ─────────────────────────────────────

    function testConfigPointsToLoanConfig() public view {
        assertEq(
            address(portfolioAccountConfig.getLoanConfig()),
            address(loanConfig),
            "PortfolioAccountConfig -> LoanConfig"
        );
    }

    function testConfigPointsToVotingConfig() public view {
        assertEq(
            portfolioAccountConfig.getVoteConfig(),
            address(votingConfig),
            "PortfolioAccountConfig -> VotingConfig"
        );
    }

    function testConfigPointsToLoanContract() public view {
        assertEq(
            portfolioAccountConfig.getLoanContract(),
            loanContract,
            "PortfolioAccountConfig -> LoanContract"
        );
    }

    function testConfigPointsToPortfolioFactory() public view {
        assertEq(
            portfolioAccountConfig.getPortfolioFactory(),
            address(portfolioFactory),
            "PortfolioAccountConfig -> PortfolioFactory"
        );
    }

    function testConfigVaultViaLoan() public view {
        assertEq(
            portfolioAccountConfig.getVault(),
            address(vault),
            "Config.getVault() should return vault via loan"
        );
    }

    // ─── VotingConfig pool management ────────────────────────────────

    function testApproveAndUnapprovePool() public {
        address testPool = address(0xCAFE);

        vm.startPrank(DEPLOYER);
        votingConfig.setApprovedPool(testPool, true);
        assertTrue(votingConfig.isApprovedPool(testPool), "Pool should be approved");

        address[] memory pools = votingConfig.getApprovedPoolsList();
        assertEq(pools.length, 1, "Should have 1 approved pool");
        assertEq(pools[0], testPool, "Approved pool should match");

        votingConfig.setApprovedPool(testPool, false);
        assertFalse(votingConfig.isApprovedPool(testPool), "Pool should be unapproved");

        pools = votingConfig.getApprovedPoolsList();
        assertEq(pools.length, 0, "Should have 0 approved pools after removal");
        vm.stopPrank();
    }

    function testVotingConfigNonOwnerReverts() public {
        address nonOwner = address(0xdead);
        vm.prank(nonOwner);
        vm.expectRevert();
        votingConfig.setApprovedPool(address(0xCAFE), true);
    }

    // ─── SwapConfig target management ────────────────────────────────

    function testApproveAndUnapproveSwapTarget() public {
        address testTarget = address(0xBEEF);

        vm.startPrank(DEPLOYER);
        swapConfig.setApprovedSwapTarget(testTarget, true);
        assertTrue(swapConfig.isApprovedSwapTarget(testTarget), "Swap target should be approved");

        address[] memory targets = swapConfig.getApprovedSwapTargetsList();
        assertEq(targets.length, 1, "Should have 1 approved target");
        assertEq(targets[0], testTarget, "Approved target should match");

        swapConfig.setApprovedSwapTarget(testTarget, false);
        assertFalse(swapConfig.isApprovedSwapTarget(testTarget), "Swap target should be unapproved");

        targets = swapConfig.getApprovedSwapTargetsList();
        assertEq(targets.length, 0, "Should have 0 approved targets after removal");
        vm.stopPrank();
    }

    function testSwapConfigNonOwnerReverts() public {
        address nonOwner = address(0xdead);
        vm.prank(nonOwner);
        vm.expectRevert();
        swapConfig.setApprovedSwapTarget(address(0xBEEF), true);
    }
}
