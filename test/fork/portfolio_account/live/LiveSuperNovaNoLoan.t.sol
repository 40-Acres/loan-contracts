// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVotingEscrow as IBlackholeVE} from "../../../../src/Blackhole/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title LiveSuperNovaNoLoan
 * @dev Fork test against Ethereum mainnet verifying that veNOVA collateral operations
 *      work correctly when no loan contract or loan config is set on the PortfolioFactoryConfig.
 *
 *      This tests the "collateral-only" deployment pattern where a factory accepts veNFT
 *      deposits before any lending infrastructure is configured.
 */
contract LiveSuperNovaNoLoan is Test {
    // SuperNova addresses (Ethereum Mainnet)
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    address public user = address(0x40ac2e);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;

    address public portfolioAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        // Deploy factory
        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(keccak256(abi.encodePacked("supernova-noloan-test")));
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        // Deploy PortfolioFactoryConfig — NO loanConfig, NO loanContract
        portfolioFactoryConfig = PortfolioFactoryConfig(address(new ERC1967Proxy(
            address(new PortfolioFactoryConfig()),
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER, address(portfolioFactory)))
        )));

        vm.stopPrank();

        // Link config to factory
        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Register facets
        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);

        _registerCollateralFacet();
        _registerVotingEscrowFacet();

        vm.stopPrank();

        // Create portfolio account
        portfolioAccount = portfolioFactory.createAccount(user);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ---- Facet Registration ----

    function _registerCollateralFacet() internal {
        CollateralFacet facet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = BaseCollateralFacet.addCollateral.selector;
        sel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        sel[2] = BaseCollateralFacet.getTotalDebt.selector;
        sel[3] = BaseCollateralFacet.getMaxLoan.selector;
        sel[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        sel[5] = BaseCollateralFacet.removeCollateral.selector;
        sel[6] = BaseCollateralFacet.getCollateralToken.selector;
        sel[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        sel[8] = BaseCollateralFacet.getLockedCollateral.selector;
        sel[9] = BaseCollateralFacet.removeCollateralTo.selector;
        sel[10] = BaseCollateralFacet.getLTVRatio.selector;
        facetRegistry.registerFacet(address(facet), sel, "CollateralFacet");
    }

    function _registerVotingEscrowFacet() internal {
        BlackholeVotingEscrowFacet facet = new BlackholeVotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        sel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        sel[2] = BlackholeVotingEscrowFacet.merge.selector;
        sel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        sel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingEscrowFacet");
    }

    // ---- Helpers ----

    function _multicallAs(address caller, bytes[] memory calldatas) internal returns (bytes[] memory) {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(portfolioFactory);
        }
        vm.prank(caller);
        return portfolioManager.multicall(calldatas, factories);
    }

    function _singleMulticall(address caller, bytes memory data) internal returns (bytes[] memory) {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        return _multicallAs(caller, calldatas);
    }

    function _createLockInAccount(uint256 amount) internal returns (uint256 tokenId) {
        deal(SNOVA_TOKEN, user, amount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(portfolioAccount, amount);
        bytes[] memory results = _singleMulticall(
            user,
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, amount)
        );
        tokenId = abi.decode(results[0], (uint256));
    }

    // ---- Tests ----

    /// @notice addCollateral succeeds with no loanConfig and no loanContract
    function testAddCollateral_noLoanConfig() public {
        uint256 tokenId = _createLockInAccount(1000e18);

        // Verify collateral is tracked
        uint256 collateral = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral, 0, "Collateral should be tracked");
        console.log("Collateral after addCollateral (no loan config):", collateral);

        // Verify debt is 0
        uint256 debt = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, 0, "Debt should be 0 without lending");

        // Verify maxLoan is 0 (no lending configured)
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "Max loan should be 0 without loan config");
        assertEq(maxLoanIgnoreSupply, 0, "Max loan ignore supply should be 0 without loan config");

        // Verify collateral requirements pass (no debt = no violations)
        bool success = ICollateralFacet(portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Collateral requirements should pass with no debt");

        // Verify LTV is 0 (no debt)
        uint256 ltv = ICollateralFacet(portfolioAccount).getLTVRatio();
        assertEq(ltv, 0, "LTV should be 0 with no debt");
    }

    /// @notice Multiple veNFTs can be added as collateral without loan config
    function testAddMultipleCollateral_noLoanConfig() public {
        uint256 tokenId1 = _createLockInAccount(500e18);
        uint256 collateral1 = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        console.log("Collateral after first lock:", collateral1);

        uint256 tokenId2 = _createLockInAccount(800e18);
        uint256 collateral2 = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        console.log("Collateral after second lock:", collateral2);

        assertGt(collateral2, collateral1, "Total collateral should increase with second deposit");

        // Both tokens tracked individually
        uint256 locked1 = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenId1);
        uint256 locked2 = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenId2);
        assertGt(locked1, 0, "Token 1 should have locked collateral");
        assertGt(locked2, 0, "Token 2 should have locked collateral");
        assertEq(locked1 + locked2, collateral2, "Individual collaterals should sum to total");
    }

    /// @notice removeCollateral succeeds with no loanConfig (no debt to check)
    function testRemoveCollateral_noLoanConfig() public {
        uint256 tokenId = _createLockInAccount(1000e18);
        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "Should have collateral");

        // Remove collateral — should succeed since there's no debt
        _singleMulticall(
            user,
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, 0, "Collateral should be 0 after removal");

        // veNFT should be back with user
        address owner = IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId);
        assertEq(owner, user, "veNFT should be returned to user");
    }

    /// @notice Full cycle: add collateral, remove it, add again — all without loan config
    function testFullCycle_addRemoveAdd_noLoanConfig() public {
        // Add
        uint256 tokenId = _createLockInAccount(1000e18);
        uint256 collateral1 = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral1, 0, "Should have collateral after first add");

        // Remove
        _singleMulticall(
            user,
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "Zero after removal");

        // Transfer veNFT back and re-add via addCollateral (token is with user now)
        vm.prank(user);
        IERC721(VOTING_ESCROW).approve(portfolioAccount, tokenId);
        _singleMulticall(
            user,
            abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId)
        );

        uint256 collateral2 = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral2, collateral1, "Collateral should match after re-add");
    }
}
