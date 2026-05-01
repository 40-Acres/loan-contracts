// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SequencerLivenessLib} from "../../src/oracle/SequencerLivenessLib.sol";
import {SequencerLivenessCheck} from "../../src/oracle/SequencerLivenessCheck.sol";
import {PortfolioFactoryConfig} from "../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockChainlinkSequencerUptimeFeed} from "../mocks/MockChainlinkSequencerUptimeFeed.sol";

/// @dev Trampoline contract so `vm.expectRevert` can target a state-mutating-context
///      call, while letting us call into the library function (which is `internal view`)
///      via this wrapper.
contract LivenessLibCaller {
    function call(address config) external view {
        SequencerLivenessLib.assertUp(config);
    }
}

/**
 * @title SequencerLivenessLibTest
 * @dev Integration tests for the assertUp helper, exercised through a real
 *      PortfolioFactoryConfig proxy + a real SequencerLivenessCheck pointed at
 *      a mock feed.
 */
contract SequencerLivenessLibTest is Test {
    PortfolioFactoryConfig internal config;
    SequencerLivenessCheck internal guard;
    MockChainlinkSequencerUptimeFeed internal feed;
    LivenessLibCaller internal caller;

    address internal constant OWNER = address(0xA110CE);
    address internal constant FACTORY_STUB = address(0xFAC701);

    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant GRACE = 1 hours;

    function setUp() public {
        vm.warp(T0);

        // Deploy real config behind ERC1967Proxy.
        PortfolioFactoryConfig impl = new PortfolioFactoryConfig();
        config = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(impl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (OWNER, FACTORY_STUB))
            ))
        );

        feed = new MockChainlinkSequencerUptimeFeed();
        feed.setStatus(0, T0 - GRACE - 1); // up + grace satisfied
        guard = new SequencerLivenessCheck(OWNER, address(feed), GRACE, 150);

        caller = new LivenessLibCaller();
    }

    // assertUp is a no-op when the config returns address(0) — protocol opt-out.
    function test_assertUp_noOpWhenGuardUnset() public view {
        assertEq(config.getSequencerLivenessCheck(), address(0), "preq: guard unset");
        // Should not revert.
        caller.call(address(config));
    }

    function test_assertUp_revertsWhenGuardDown() public {
        vm.prank(OWNER);
        config.setSequencerLivenessCheck(address(guard));

        // Flip guard to "down" — sequencer reports answer == 1.
        feed.setStatus(1, T0 - GRACE - 1);

        vm.expectRevert(SequencerLivenessLib.SequencerDown.selector);
        caller.call(address(config));
    }

    function test_assertUp_revertsWhenGuardWithinGrace() public {
        vm.prank(OWNER);
        config.setSequencerLivenessCheck(address(guard));

        // Sequencer just came back up — within grace window.
        feed.setStatus(0, T0 - (GRACE / 2));

        vm.expectRevert(SequencerLivenessLib.SequencerDown.selector);
        caller.call(address(config));
    }

    function test_assertUp_noOpWhenGuardUp() public {
        vm.prank(OWNER);
        config.setSequencerLivenessCheck(address(guard));
        // Default mock state: up + grace satisfied. Should not revert.
        caller.call(address(config));
    }

    function test_assertUp_noOpWhenGuardFeedIsZero() public {
        // Set guard whose feed is then zeroed (Linea/Ink opt-out path).
        vm.prank(OWNER);
        config.setSequencerLivenessCheck(address(guard));
        vm.prank(OWNER);
        guard.setFeed(address(0));

        // Should not revert — guard treats zero-feed as up.
        caller.call(address(config));
    }
}
