// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseForkSetup} from "./BaseForkSetup.sol";
import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AerodromeClaimingRegression
 * @dev Verifies ClaimingFacet config wiring and that claiming flows
 *      (claimFees, claimRebase) work correctly with the deployed system.
 */
contract AerodromeClaimingRegression is BaseForkSetup {
    // Known data at fork block 38869188
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address[] public bribes = [0x765d935C2F47a06EdA55D07a9b9aE4108F4BBF85];
    address[][] public poolTokens;

    uint256 constant EXPECTED_WETH_REWARD = 1090570742412276;
    uint256 constant EXPECTED_USDC_REWARD = 3462465;
    uint256 constant EXPECTED_REBASE_INCREASE = 1128188206630704788;

    function setUp() public override {
        super.setUp();

        // Build the 2D token array for claimFees
        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        poolTokens.push(tokens);

        // Add collateral (needed for claimRebase's updateLockedCollateral)
        _addCollateral(tokenId);
    }

    // ─── ClaimingFacet config wiring ────────────────────────────────

    function testClaimingFacetPortfolioFactory() public view {
        assertEq(address(claimingFacet._portfolioFactory()), address(portfolioFactory));
    }

    function testClaimingFacetPortfolioAccountConfig() public view {
        assertEq(address(claimingFacet._portfolioAccountConfig()), address(portfolioAccountConfig));
    }

    function testClaimingFacetVotingEscrow() public view {
        assertEq(address(claimingFacet._votingEscrow()), VOTING_ESCROW);
    }

    function testClaimingFacetVoter() public view {
        assertEq(address(claimingFacet._voter()), VOTER);
    }

    function testClaimingFacetRewardsDistributor() public view {
        assertEq(address(claimingFacet._rewardsDistributor()), REWARDS_DISTRIBUTOR);
    }

    function testClaimingFacetLoanConfig() public view {
        assertEq(address(claimingFacet._loanConfig()), address(loanConfig));
    }

    function testClaimingFacetSwapConfig() public view {
        assertEq(address(claimingFacet._swapConfig()), address(swapConfig));
    }

    function testClaimingFacetVault() public view {
        assertEq(address(claimingFacet._vault()), address(vault));
    }

    // ─── Authorized caller ──────────────────────────────────────────

    function testAuthorizedCallerIsSet() public view {
        assertTrue(portfolioManager.isAuthorizedCaller(authorizedCaller));
    }

    // ─── claimFees works ────────────────────────────────────────────

    function testClaimFeesDeliversRewards() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(portfolioAccount);
        uint256 usdcBefore = IERC20(USDC).balanceOf(portfolioAccount);

        ClaimingFacet(portfolioAccount).claimFees(bribes, poolTokens, tokenId);

        assertEq(IERC20(WETH).balanceOf(portfolioAccount) - wethBefore, EXPECTED_WETH_REWARD, "WETH reward mismatch");
        assertEq(IERC20(USDC).balanceOf(portfolioAccount) - usdcBefore, EXPECTED_USDC_REWARD, "USDC reward mismatch");
    }

    // ─── claimRebase works ──────────────────────────────────────────

    function testClaimRebaseIncreasesLockedAmount() public {
        int128 lockedBefore = IVotingEscrow(VOTING_ESCROW).locked(tokenId).amount;

        ClaimingFacet(portfolioAccount).claimRebase(tokenId);

        int128 lockedAfter = IVotingEscrow(VOTING_ESCROW).locked(tokenId).amount;
        assertEq(lockedAfter, lockedBefore + int128(int256(EXPECTED_REBASE_INCREASE)), "Rebase should increase locked amount");
    }

    function testClaimRebaseUpdatesCollateral() public {
        uint256 collateralBefore = CollateralFacet(portfolioAccount).getTotalLockedCollateral();

        ClaimingFacet(portfolioAccount).claimRebase(tokenId);

        uint256 collateralAfter = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralAfter, collateralBefore, "Collateral should increase after rebase");
    }

    // ─── claimFees also triggers rebase ─────────────────────────────

    function testClaimFeesAlsoClaimsRebase() public {
        int128 lockedBefore = IVotingEscrow(VOTING_ESCROW).locked(tokenId).amount;

        ClaimingFacet(portfolioAccount).claimFees(bribes, poolTokens, tokenId);

        int128 lockedAfter = IVotingEscrow(VOTING_ESCROW).locked(tokenId).amount;
        assertGt(lockedAfter, lockedBefore, "claimFees should also trigger rebase");
    }
}
