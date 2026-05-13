// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";

/**
 * @title RewardsConfigFacetAllowlistTest
 * @dev Verifies the SwapConfig-driven allowlist gates added to
 *      setVaultForInvesting, setZeroBalanceDistribution, and setActiveBalanceDistribution.
 */
contract RewardsConfigFacetAllowlistTest is LocalSetup {
    RewardsConfigFacet internal rewardsConfigFacet;

    address internal approvedVault = address(0xA000);
    address internal unapprovedVault = address(0xB000);
    address internal approvedOutputToken = address(0xC000);
    address internal unapprovedOutputToken = address(0xD000);
    address internal someRecipient = address(0xE000);

    function setUp() public override {
        super.setUp();

        // Register the extra RewardsConfigFacet selectors not in the default LocalSetup
        // wiring -- specifically setVaultForInvesting and getVaultForInvesting.
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        RewardsConfigFacet configFacetForExtras = new RewardsConfigFacet(address(_portfolioFactory), address(_swapConfig));
        bytes4[] memory extraSel = new bytes4[](2);
        extraSel[0] = RewardsConfigFacet.setVaultForInvesting.selector;
        extraSel[1] = RewardsConfigFacet.getVaultForInvesting.selector;
        _facetRegistry.registerFacet(address(configFacetForExtras), extraSel, "RewardsConfigFacetExtras");

        // Approve one vault and one output token in the SwapConfig
        _swapConfig.setApprovedVault(approvedVault, true);
        _swapConfig.setApprovedOutputToken(approvedOutputToken, true);
        vm.stopPrank();

        rewardsConfigFacet = RewardsConfigFacet(_portfolioAccount);
    }

    // ────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────

    function _setVaultForInvesting(address vault) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setVaultForInvesting.selector, vault);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _setZeroBalanceDistribution(UserRewardsConfig.DistributionEntry[] memory entries) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setZeroBalanceDistribution.selector, entries);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _setActiveBalanceDistribution(UserRewardsConfig.DistributionEntry memory entry) internal {
        vm.startPrank(_user);
        address[] memory pf = new address[](1);
        pf[0] = address(_portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(RewardsConfigFacet.setActiveBalanceDistribution.selector, entry);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function _entry(
        UserRewardsConfig.RewardsOption option,
        uint256 percentage,
        address outputToken_,
        address target_
    ) internal pure returns (UserRewardsConfig.DistributionEntry memory) {
        return UserRewardsConfig.DistributionEntry({
            option: option,
            percentage: percentage,
            outputToken: outputToken_,
            target: target_
        });
    }

    function _singletonEntries(
        UserRewardsConfig.DistributionEntry memory entry
    ) internal pure returns (UserRewardsConfig.DistributionEntry[] memory entries) {
        entries = new UserRewardsConfig.DistributionEntry[](1);
        entries[0] = entry;
    }

    // ────────────────────────────────────────────────────────────────
    // setVaultForInvesting
    // ────────────────────────────────────────────────────────────────

    function test_setVaultForInvesting_zeroAddressReverts() public {
        vm.expectRevert(bytes("Vault not approved"));
        _setVaultForInvesting(address(0));
    }

    function test_setVaultForInvesting_unapprovedReverts() public {
        vm.expectRevert(bytes("Vault not approved"));
        _setVaultForInvesting(unapprovedVault);
    }

    function test_setVaultForInvesting_approvedSucceeds() public {
        _setVaultForInvesting(approvedVault);
        assertEq(rewardsConfigFacet.getVaultForInvesting(), approvedVault, "stored vault matches");
    }

    // ────────────────────────────────────────────────────────────────
    // setZeroBalanceDistribution -- InvestToVault
    // ────────────────────────────────────────────────────────────────

    function test_setZero_investToVault_zeroTargetReverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.InvestToVault, 100, address(0), address(0))
        );
        vm.expectRevert(bytes("InvestToVault target not approved"));
        _setZeroBalanceDistribution(entries);
    }

    function test_setZero_investToVault_unapprovedTargetReverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.InvestToVault, 100, address(0), unapprovedVault)
        );
        vm.expectRevert(bytes("InvestToVault target not approved"));
        _setZeroBalanceDistribution(entries);
    }

    function test_setZero_investToVault_approvedTargetSucceeds() public {
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.InvestToVault, 100, address(0), approvedVault)
        );
        _setZeroBalanceDistribution(entries);

        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 1, "stored length=1");
        assertEq(uint8(stored[0].option), uint8(UserRewardsConfig.RewardsOption.InvestToVault), "option");
        assertEq(stored[0].target, approvedVault, "target");
        assertEq(stored[0].percentage, 100, "percentage");
    }

    // ────────────────────────────────────────────────────────────────
    // setZeroBalanceDistribution -- PayToRecipient
    // ────────────────────────────────────────────────────────────────

    function test_setZero_payToRecipient_zeroOutputTokenSucceeds() public {
        // outputToken == address(0) is the "use default rewards asset" fallback and is allowed.
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.PayToRecipient, 100, address(0), someRecipient)
        );
        _setZeroBalanceDistribution(entries);

        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 1, "stored length=1");
        assertEq(stored[0].outputToken, address(0), "outputToken=0");
        assertEq(stored[0].target, someRecipient, "target=recipient");
    }

    function test_setZero_payToRecipient_unapprovedOutputTokenReverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.PayToRecipient, 100, unapprovedOutputToken, someRecipient)
        );
        vm.expectRevert(bytes("PayToRecipient outputToken not approved"));
        _setZeroBalanceDistribution(entries);
    }

    function test_setZero_payToRecipient_approvedOutputTokenSucceeds() public {
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.PayToRecipient, 100, approvedOutputToken, someRecipient)
        );
        _setZeroBalanceDistribution(entries);

        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 1, "stored length=1");
        assertEq(stored[0].outputToken, approvedOutputToken, "outputToken=approved");
        assertEq(stored[0].target, someRecipient, "target=recipient");
    }

    // ────────────────────────────────────────────────────────────────
    // setZeroBalanceDistribution -- options with no validation
    // ────────────────────────────────────────────────────────────────

    function test_setZero_payBalance_ignoresTargetAndOutputToken() public {
        // PayBalance is the per-network default and has no allowlist gate;
        // any target/outputToken values should pass through untouched.
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.PayBalance, 50, unapprovedOutputToken, unapprovedVault)
        );
        _setZeroBalanceDistribution(entries);

        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 1, "stored length=1");
        assertEq(uint8(stored[0].option), uint8(UserRewardsConfig.RewardsOption.PayBalance), "option=PayBalance");
        assertEq(stored[0].outputToken, unapprovedOutputToken, "outputToken pass-through");
        assertEq(stored[0].target, unapprovedVault, "target pass-through");
    }

    function test_setZero_increaseCollateral_ignoresTargetAndOutputToken() public {
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.IncreaseCollateral, 75, unapprovedOutputToken, unapprovedVault)
        );
        _setZeroBalanceDistribution(entries);

        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 1, "stored length=1");
        assertEq(uint8(stored[0].option), uint8(UserRewardsConfig.RewardsOption.IncreaseCollateral), "option=IncreaseCollateral");
    }

    // ────────────────────────────────────────────────────────────────
    // setZeroBalanceDistribution -- PayDebt validation still works
    // ────────────────────────────────────────────────────────────────

    function test_setZero_payDebt_zeroTargetSucceeds() public {
        // target=0 means "this factory" -- no factory registry check needed.
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.PayDebt, 100, address(0), address(0))
        );
        _setZeroBalanceDistribution(entries);

        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 1, "stored length=1");
        assertEq(uint8(stored[0].option), uint8(UserRewardsConfig.RewardsOption.PayDebt), "option=PayDebt");
    }

    function test_setZero_payDebt_nonRegisteredFactoryReverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = _singletonEntries(
            _entry(UserRewardsConfig.RewardsOption.PayDebt, 100, address(0), address(0xDEADBEEF))
        );
        vm.expectRevert(bytes("PayDebt target must be registered factory"));
        _setZeroBalanceDistribution(entries);
    }

    // ────────────────────────────────────────────────────────────────
    // setZeroBalanceDistribution -- multi-entry validation
    // ────────────────────────────────────────────────────────────────

    function test_setZero_mixedEntries_anyInvalidReverts() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = _entry(UserRewardsConfig.RewardsOption.PayBalance, 50, address(0), address(0));
        entries[1] = _entry(UserRewardsConfig.RewardsOption.InvestToVault, 50, address(0), unapprovedVault);

        vm.expectRevert(bytes("InvestToVault target not approved"));
        _setZeroBalanceDistribution(entries);
    }

    function test_setZero_mixedEntries_allValidSucceeds() public {
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](2);
        entries[0] = _entry(UserRewardsConfig.RewardsOption.InvestToVault, 40, address(0), approvedVault);
        entries[1] = _entry(UserRewardsConfig.RewardsOption.PayToRecipient, 60, approvedOutputToken, someRecipient);
        _setZeroBalanceDistribution(entries);

        UserRewardsConfig.DistributionEntry[] memory stored = rewardsConfigFacet.getZeroBalanceDistribution();
        assertEq(stored.length, 2, "stored length=2");
        assertEq(stored[0].target, approvedVault, "[0] target");
        assertEq(stored[1].outputToken, approvedOutputToken, "[1] outputToken");
    }

    // ────────────────────────────────────────────────────────────────
    // setActiveBalanceDistribution -- mirror of zero-balance matrix
    // ────────────────────────────────────────────────────────────────

    function test_setActive_investToVault_zeroTargetReverts() public {
        vm.expectRevert(bytes("InvestToVault target not approved"));
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.InvestToVault, 100, address(0), address(0))
        );
    }

    function test_setActive_investToVault_unapprovedTargetReverts() public {
        vm.expectRevert(bytes("InvestToVault target not approved"));
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.InvestToVault, 100, address(0), unapprovedVault)
        );
    }

    function test_setActive_investToVault_approvedTargetSucceeds() public {
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.InvestToVault, 100, address(0), approvedVault)
        );

        UserRewardsConfig.DistributionEntry memory stored = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(uint8(stored.option), uint8(UserRewardsConfig.RewardsOption.InvestToVault), "option");
        assertEq(stored.target, approvedVault, "target");
    }

    function test_setActive_payToRecipient_zeroOutputTokenSucceeds() public {
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.PayToRecipient, 100, address(0), someRecipient)
        );

        UserRewardsConfig.DistributionEntry memory stored = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(stored.outputToken, address(0), "outputToken=0");
        assertEq(stored.target, someRecipient, "target=recipient");
    }

    function test_setActive_payToRecipient_unapprovedOutputTokenReverts() public {
        vm.expectRevert(bytes("PayToRecipient outputToken not approved"));
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.PayToRecipient, 100, unapprovedOutputToken, someRecipient)
        );
    }

    function test_setActive_payToRecipient_approvedOutputTokenSucceeds() public {
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.PayToRecipient, 100, approvedOutputToken, someRecipient)
        );

        UserRewardsConfig.DistributionEntry memory stored = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(stored.outputToken, approvedOutputToken, "outputToken=approved");
        assertEq(stored.target, someRecipient, "target=recipient");
    }

    function test_setActive_payBalance_ignoresTargetAndOutputToken() public {
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.PayBalance, 100, unapprovedOutputToken, unapprovedVault)
        );

        UserRewardsConfig.DistributionEntry memory stored = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(uint8(stored.option), uint8(UserRewardsConfig.RewardsOption.PayBalance), "option=PayBalance");
        assertEq(stored.outputToken, unapprovedOutputToken, "outputToken pass-through");
        assertEq(stored.target, unapprovedVault, "target pass-through");
    }

    function test_setActive_increaseCollateral_ignoresTargetAndOutputToken() public {
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.IncreaseCollateral, 100, unapprovedOutputToken, unapprovedVault)
        );

        UserRewardsConfig.DistributionEntry memory stored = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(uint8(stored.option), uint8(UserRewardsConfig.RewardsOption.IncreaseCollateral), "option=IncreaseCollateral");
    }

    function test_setActive_payDebt_zeroTargetSucceeds() public {
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.PayDebt, 100, address(0), address(0))
        );

        UserRewardsConfig.DistributionEntry memory stored = rewardsConfigFacet.getActiveBalanceDistribution();
        assertEq(uint8(stored.option), uint8(UserRewardsConfig.RewardsOption.PayDebt), "option=PayDebt");
    }

    function test_setActive_payDebt_nonRegisteredFactoryReverts() public {
        vm.expectRevert(bytes("PayDebt target must be registered factory"));
        _setActiveBalanceDistribution(
            _entry(UserRewardsConfig.RewardsOption.PayDebt, 100, address(0), address(0xDEADBEEF))
        );
    }
}
