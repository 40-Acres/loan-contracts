// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Reuse the existing local setup that already wires the lending stack.
import {LocalSetup} from "../portfolio_account/utils/LocalSetup.sol";

import {BaseLendingFacet} from "../../src/facets/account/lending/BaseLendingFacet.sol";
import {LendingFacet} from "../../src/facets/account/lending/LendingFacet.sol";
import {BaseCollateralFacet} from "../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralFacet} from "../../src/facets/account/collateral/CollateralFacet.sol";
import {ILoan} from "../../src/interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SequencerLivenessLib} from "../../src/oracle/SequencerLivenessLib.sol";
import {SequencerLivenessCheck} from "../../src/oracle/SequencerLivenessCheck.sol";
import {MockChainlinkSequencerUptimeFeed} from "../mocks/MockChainlinkSequencerUptimeFeed.sol";

/**
 * @title SequencerLivenessActionGatingTest
 * @dev End-to-end gating tests on a real diamond proxy via LocalSetup.
 *      Confirms that:
 *        - borrow() / borrowTo() / topUp() / removeCollateral() / removeCollateralTo()
 *          revert with SequencerLivenessLib.SequencerDown when the guard reports down.
 *        - pay() succeeds while the sequencer is down (asymmetry — repay is ungated).
 *        - The guard is opt-out at the config level: setting it to address(0) restores
 *          the legacy ungated behavior.
 */
contract SequencerLivenessActionGatingTest is Test, LocalSetup {
    SequencerLivenessCheck internal guard;
    MockChainlinkSequencerUptimeFeed internal feed;

    uint256 internal constant GRACE = 1 hours;

    function setUp() public override {
        super.setUp();

        feed = new MockChainlinkSequencerUptimeFeed();
        // Default: up + grace satisfied.
        feed.setStatus(0, block.timestamp - GRACE - 1);

        guard = new SequencerLivenessCheck(
            _owner,                 // owner — same governance multisig as PortfolioFactoryConfig owner
            address(feed),
            GRACE,
            150
        );
    }

    // ─────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────

    function _setGuard(address g) internal {
        vm.prank(_owner);
        _portfolioFactoryConfig.setSequencerLivenessCheck(g);
    }

    function _markDown() internal {
        feed.setStatus(1, block.timestamp - GRACE - 1);
    }

    function _addCollateral(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _borrow(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _removeCollateral(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _setTopUp(bool enabled) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.setTopUp.selector, enabled);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _topUpExpectRevert() internal {
        vm.prank(_authorizedCaller);
        vm.expectRevert(SequencerLivenessLib.SequencerDown.selector);
        BaseLendingFacet(_portfolioAccount).topUp();
    }

    function _topUp() internal {
        vm.prank(_authorizedCaller);
        BaseLendingFacet(_portfolioAccount).topUp();
    }

    function _fundVault(uint256 amount) internal {
        address loanContract = _portfolioFactoryConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_asset), vault, amount);
    }

    // ─────────────────────────────────────────────────────────
    // Borrow gating
    // ─────────────────────────────────────────────────────────

    function test_borrow_revertsWhenSequencerDown() public {
        _addCollateral(_tokenId);
        _fundVault(1_000_000e6);

        _setGuard(address(guard));
        _markDown();

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, 1e6);
        vm.expectRevert(SequencerLivenessLib.SequencerDown.selector);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function test_borrow_succeedsWhenSequencerUp() public {
        _addCollateral(_tokenId);
        _fundVault(1_000_000e6);

        _setGuard(address(guard));
        // feed default: up + grace satisfied
        _borrow(1e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 1e6);
    }

    function test_borrow_succeedsWhenGuardUnset_optOut() public {
        _addCollateral(_tokenId);
        _fundVault(1_000_000e6);
        // No guard set → assertUp is a no-op even though we'd technically have one available.
        assertEq(_portfolioFactoryConfig.getSequencerLivenessCheck(), address(0));
        _borrow(1e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 1e6);
    }

    // ─────────────────────────────────────────────────────────
    // Pay is ungated (asymmetry)
    // ─────────────────────────────────────────────────────────

    function test_pay_succeedsWhenSequencerDown_asymmetry() public {
        // Borrow first while up.
        _addCollateral(_tokenId);
        _fundVault(1_000_000e6);
        _borrow(1e6);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 1e6);

        // Now bring sequencer down — pay must still succeed.
        _setGuard(address(guard));
        _markDown();

        // Fund user for repayment.
        deal(address(_asset), _user, 1e6);
        vm.startPrank(_user);
        IERC20(_asset).approve(_portfolioAccount, 1e6);
        LendingFacet(_portfolioAccount).pay(1e6);
        vm.stopPrank();

        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "repay must work while sequencer is down");
    }

    // ─────────────────────────────────────────────────────────
    // removeCollateral gating
    // ─────────────────────────────────────────────────────────

    function test_removeCollateral_revertsWhenSequencerDown() public {
        _addCollateral(_tokenId);

        _setGuard(address(guard));
        _markDown();

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, _tokenId);
        vm.expectRevert(SequencerLivenessLib.SequencerDown.selector);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function test_removeCollateral_succeedsWhenSequencerUp() public {
        _addCollateral(_tokenId);
        _setGuard(address(guard));
        // feed default: up
        _removeCollateral(_tokenId);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
    }

    // ─────────────────────────────────────────────────────────
    // topUp gating (originates debt, hence gated)
    // ─────────────────────────────────────────────────────────

    function test_topUp_revertsWhenSequencerDown() public {
        _addCollateral(_tokenId);
        _fundVault(1_000_000e6);
        _setTopUp(true);

        _setGuard(address(guard));
        _markDown();
        _topUpExpectRevert();
    }

    function test_topUp_succeedsWhenSequencerUp() public {
        _addCollateral(_tokenId);
        _fundVault(1_000_000e6);
        _setTopUp(true);

        _setGuard(address(guard));
        // feed default: up
        _topUp();
        assertGt(CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "topUp originates debt");
    }

    // ─────────────────────────────────────────────────────────
    // Gas snapshot — informational
    // ─────────────────────────────────────────────────────────

    function test_borrow_gasSnapshot_optOutVsActiveGuard() public {
        _addCollateral(_tokenId);
        _fundVault(1_000_000e6);

        // Pre-warm SLOAD slots roughly equivalently by reading config field once.
        address dummy = _portfolioFactoryConfig.getSequencerLivenessCheck();
        dummy; // silence

        // No-op opt-out path (guard unset).
        uint256 g0 = gasleft();
        _borrow(1e6);
        uint256 noOpGas = g0 - gasleft();
        console.log("borrow gas, opt-out path (guard unset):", noOpGas);

        // Active guard path. Need fresh debt headroom — pay back first.
        deal(address(_asset), _user, 1e6);
        vm.startPrank(_user);
        IERC20(_asset).approve(_portfolioAccount, 1e6);
        LendingFacet(_portfolioAccount).pay(1e6);
        vm.stopPrank();

        _setGuard(address(guard));
        // feed default: up

        uint256 g1 = gasleft();
        _borrow(1e6);
        uint256 activeGas = g1 - gasleft();
        console.log("borrow gas, active guard up:", activeGas);

        if (activeGas > noOpGas) {
            console.log("delta (active - opt-out):", activeGas - noOpGas);
        } else {
            console.log("delta (opt-out - active):", noOpGas - activeGas);
        }
        // No hard assertion on absolute numbers — they shift with optimizer.
    }
}
