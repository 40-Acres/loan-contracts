// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * RewardsProcessingFacet — treasury routing.
 *
 * Pins the swap site at L432 (zeroBalanceFee) and L485 (protocolFee) which
 * now read `config.getLoanConfig().getTreasury()` instead of `config.owner()`.
 *
 * Coverage (via the existing LocalSetup harness):
 *   - With treasury UNSET, the zero-balance fee STILL lands at owner() via
 *     the LoanConfig.getTreasury() fallback. Validates the fallback in the
 *     hot path, not just the view.
 *   - After LoanConfig.setTreasury(T), the zero-balance fee lands at T, NOT
 *     at the owner. Validates the swap from owner() to getTreasury() at the
 *     transfer site.
 *
 * Note: protocolFee (L485) lives behind the with-debt branch and the
 *       LocalSetup wiring does not exercise that branch from the
 *       no-collateral fixture without significant additional setup. The
 *       zeroBalanceFee path proves the swap-site read of LoanConfig is
 *       working; the protocolFee path uses the identical read pattern
 *       (`config.getLoanConfig().getTreasury()`). The vault-level pay-fee
 *       routing is covered by LendingVaultTreasury / DynamicFeesVaultTreasuryAddress.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {DeployRewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployRewardsProcessingFacet.s.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";

contract RewardsProcessingTreasuryTest is Test, LocalSetup {
    RewardsProcessingFacet public rewardsProcessingFacet;
    MockOdosRouterRL public mockRouter;

    address public rewardsToken;
    uint256 public rewardsAmount = 1000e6; // 1000 USDC
    address public recipient = address(0x1234);

    // Distinct from FORTY_ACRES_DEPLOYER (LoanConfig owner) so the routing
    // assertion is unambiguous: a fee at `treasury` proves the swap.
    address public treasury = address(0x7EA51);

    function setUp() public override {
        super.setUp();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_swapConfig), address(_ve), _vault);
        vm.stopPrank();

        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);

        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        rewardsToken = address(_usdc);

        // Wire the user's rewards config: recipient + collateral attached.
        vm.startPrank(_user);
        address[] memory pfArr = new address[](2);
        pfArr[0] = address(_portfolioFactory);
        pfArr[1] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(
            RewardsConfigFacet.setRecipient.selector,
            recipient
        );
        calldatas[1] = abi.encodeWithSelector(
            BaseCollateralFacet.addCollateral.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, pfArr);
        vm.stopPrank();

        vm.prank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
    }

    function _fund() internal {
        deal(rewardsToken, _portfolioAccount, rewardsAmount);
    }

    function _processRewards() internal {
        vm.startPrank(_authorizedCaller);
        SwapMod.RouteParams[4] memory noSwap;
        rewardsProcessingFacet.processRewards(_tokenId, rewardsAmount, noSwap, 0);
        vm.stopPrank();
    }

    /// @notice Sanity-pin: pre-treasury-feature behavior is preserved.
    ///         With treasury UNSET, zero-balance fee still arrives at owner()
    ///         via LoanConfig.getTreasury()'s fallback. If the swap had been
    ///         done by replacing the recipient hardcode with `address(0)`,
    ///         the USDC would be burned and this test would catch it.
    function test_zeroBalanceFee_unsetTreasury_routesToOwnerViaFallback() public {
        _fund();
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "fixture sanity");

        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(FORTY_ACRES_DEPLOYER);
        uint256 treasuryBefore = IERC20(rewardsToken).balanceOf(treasury);

        _processRewards();

        uint256 zeroBalanceBps = _loanConfig.getZeroBalanceFee();
        uint256 expectedFee = (rewardsAmount * zeroBalanceBps) / 10000;
        assertGt(expectedFee, 0, "test sanity: fee must be non-zero");

        assertEq(
            IERC20(rewardsToken).balanceOf(FORTY_ACRES_DEPLOYER) - ownerBefore,
            expectedFee,
            "owner receives zero-balance fee via getTreasury() fallback"
        );
        assertEq(IERC20(rewardsToken).balanceOf(treasury), treasuryBefore, "treasury untouched while unset");
    }

    /// @notice Core swap-site validation: after LoanConfig.setTreasury(T),
    ///         the zero-balance fee MUST arrive at T and the owner MUST NOT
    ///         receive anything.
    function test_zeroBalanceFee_setTreasury_routesToTreasuryNotOwner() public {
        vm.prank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setTreasury(treasury);

        _fund();

        uint256 ownerBefore = IERC20(rewardsToken).balanceOf(FORTY_ACRES_DEPLOYER);
        uint256 treasuryBefore = IERC20(rewardsToken).balanceOf(treasury);

        _processRewards();

        uint256 zeroBalanceBps = _loanConfig.getZeroBalanceFee();
        uint256 expectedFee = (rewardsAmount * zeroBalanceBps) / 10000;

        assertEq(
            IERC20(rewardsToken).balanceOf(treasury) - treasuryBefore,
            expectedFee,
            "treasury receives the zero-balance fee"
        );
        assertEq(
            IERC20(rewardsToken).balanceOf(FORTY_ACRES_DEPLOYER),
            ownerBefore,
            "owner must NOT receive the zero-balance fee after setTreasury"
        );
    }
}
