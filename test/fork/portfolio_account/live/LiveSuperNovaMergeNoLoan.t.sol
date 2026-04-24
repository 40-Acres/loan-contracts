// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
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
 * @title LiveSuperNovaMergeNoLoan
 * @dev Sibling to LiveSuperNovaMerge. SuperNova deployment WITH LoanConfig
 *      but WITHOUT loan contract and vault. Verifies merge and mergeInternal
 *      flows are identical in the collateral-only deployment.
 */
contract LiveSuperNovaMergeNoLoan is Test {
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
    LoanConfig public loanConfig;

    address public portfolioAccount;

    uint256 constant LOCK_AMOUNT_1 = 100e18;
    uint256 constant LOCK_AMOUNT_2 = 200e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("supernova-merge-noloan-test"))
        );
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        portfolioFactoryConfig = PortfolioFactoryConfig(address(new ERC1967Proxy(
            address(new PortfolioFactoryConfig()),
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER, address(portfolioFactory)))
        )));
        VotingConfig votingConfig = VotingConfig(address(new ERC1967Proxy(
            address(new VotingConfig()),
            abi.encodeCall(VotingConfig.initialize, (DEPLOYER))
        )));
        loanConfig = LoanConfig(address(new ERC1967Proxy(
            address(new LoanConfig()),
            abi.encodeCall(LoanConfig.initialize, (DEPLOYER, 20_00, 5_00, 1_00))
        )));
        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));
        // loanContract intentionally NOT set.

        vm.stopPrank();

        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);

        CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory colSel = new bytes4[](11);
        colSel[0] = BaseCollateralFacet.addCollateral.selector;
        colSel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        colSel[2] = BaseCollateralFacet.getTotalDebt.selector;
        colSel[3] = BaseCollateralFacet.getMaxLoan.selector;
        colSel[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        colSel[5] = BaseCollateralFacet.removeCollateral.selector;
        colSel[6] = BaseCollateralFacet.getCollateralToken.selector;
        colSel[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        colSel[8] = BaseCollateralFacet.getLockedCollateral.selector;
        colSel[9] = BaseCollateralFacet.removeCollateralTo.selector;
        colSel[10] = BaseCollateralFacet.getLTVRatio.selector;
        facetRegistry.registerFacet(address(collateralFacet), colSel, "CollateralFacet");

        BlackholeVotingEscrowFacet veFacet = new BlackholeVotingEscrowFacet(
            address(portfolioFactory), VOTING_ESCROW, VOTER
        );
        bytes4[] memory veSel = new bytes4[](5);
        veSel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        veSel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        veSel[2] = BlackholeVotingEscrowFacet.merge.selector;
        veSel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        veSel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        facetRegistry.registerFacet(address(veFacet), veSel, "VotingEscrowFacet");

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        assertEq(
            portfolioFactoryConfig.getLoanContract(),
            address(0),
            "loanContract must be unset for this suite"
        );
    }

    function _assertNoLoan() internal view {
        assertEq(portfolioFactoryConfig.getLoanContract(), address(0), "invariant: no loan");
    }

    // ── Helpers ──

    function _multicallAsUser(bytes[] memory calldatas) internal returns (bytes[] memory) {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(portfolioFactory);
        }
        vm.prank(user);
        return portfolioManager.multicall(calldatas, factories);
    }

    function _singleMulticall(bytes memory data) internal returns (bytes[] memory) {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        return _multicallAsUser(calldatas);
    }

    function _createLockInAccount(uint256 amount) internal returns (uint256 tokenId) {
        deal(SNOVA_TOKEN, user, amount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(portfolioAccount, amount);
        bytes[] memory results = _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, amount)
        );
        tokenId = abi.decode(results[0], (uint256));
    }

    function _createExternalLock(uint256 amount) internal returns (uint256 tokenId) {
        deal(SNOVA_TOKEN, user, amount);
        vm.startPrank(user);
        IERC20(SNOVA_TOKEN).approve(VOTING_ESCROW, amount);
        tokenId = IBlackholeVE(VOTING_ESCROW).create_lock_for(amount, 4 * 365 days, user, false);
        vm.stopPrank();
    }

    // ── Tests: mergeInternal ──

    function testMergeInternal_happyPath_noLoan() public {
        _assertNoLoan();
        uint256 tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        address ownerA = IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdA);
        assertTrue(ownerA == address(0) || ownerA != portfolioAccount, "A burned or removed");

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA), 0, "A zeroed");
        assertEq(collateralAfter, collateralBefore, "total preserved");
    }

    function testMergeInternal_veLockedAmountCombined_noLoan() public {
        _assertNoLoan();
        uint256 tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        IBlackholeVE.LockedBalance memory lockedA = IBlackholeVE(VOTING_ESCROW).locked(tokenIdA);
        IBlackholeVE.LockedBalance memory lockedB = IBlackholeVE(VOTING_ESCROW).locked(tokenIdB);
        uint256 rawA = uint256(uint128(lockedA.amount));
        uint256 rawB = uint256(uint128(lockedB.amount));

        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        IBlackholeVE.LockedBalance memory mergedLock = IBlackholeVE(VOTING_ESCROW).locked(tokenIdB);
        uint256 mergedRaw = uint256(uint128(mergedLock.amount));
        assertEq(mergedRaw, rawA + rawB, "raw locked combined");
    }

    function testMergeInternal_collateralPreserved_noLoan() public {
        _assertNoLoan();
        uint256 tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        uint256 totalBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        uint256 totalAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(totalAfter, totalBefore, "total preserved");
        uint256 survivor = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB);
        assertEq(survivor, totalAfter, "survivor holds all");
    }

    function testMergeInternal_revertSameToken_noLoan() public {
        _assertNoLoan();
        uint256 tokenId = _createLockInAccount(LOCK_AMOUNT_1);

        vm.expectRevert("SameNFT");
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenId, tokenId)
        );
    }

    // ── Tests: external merge ──

    function testMerge_externalHappyPath_noLoan() public {
        _assertNoLoan();
        uint256 accountToken = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 externalToken = _createExternalLock(LOCK_AMOUNT_2);

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        IBlackholeVE.LockedBalance memory lockedAccount = IBlackholeVE(VOTING_ESCROW).locked(accountToken);
        IBlackholeVE.LockedBalance memory lockedExternal = IBlackholeVE(VOTING_ESCROW).locked(externalToken);
        uint256 rawAccount = uint256(uint128(lockedAccount.amount));
        uint256 rawExternal = uint256(uint128(lockedExternal.amount));

        vm.prank(user);
        IERC721(VOTING_ESCROW).approve(portfolioAccount, externalToken);

        vm.prank(user);
        BlackholeVotingEscrowFacet(portfolioAccount).merge(externalToken, accountToken);

        IBlackholeVE.LockedBalance memory mergedLock = IBlackholeVE(VOTING_ESCROW).locked(accountToken);
        uint256 mergedRaw = uint256(uint128(mergedLock.amount));
        // merge may credit accrued rebase to the surviving token; lower bound is the raw sum.
        assertGe(mergedRaw, rawAccount + rawExternal, "ve amount at least combined");

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralAfter, collateralBefore, "collateral increased");
        assertEq(collateralAfter, mergedRaw, "collateral matches ve");

        // External token burned / transferred away
        address externalOwner = IVotingEscrow(VOTING_ESCROW).ownerOf(externalToken);
        assertTrue(
            externalOwner == address(0) || externalOwner != user,
            "external token no longer user-owned"
        );
    }

    function testMerge_revertToTokenNotInAccount_noLoan() public {
        _assertNoLoan();
        uint256 externalToken = _createExternalLock(LOCK_AMOUNT_1);

        vm.prank(user);
        vm.expectRevert();
        BlackholeVotingEscrowFacet(portfolioAccount).merge(externalToken, 999999);
    }

    function testMerge_revertFromTokenInAccount_noLoan() public {
        _assertNoLoan();
        uint256 tokenA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenB = _createLockInAccount(LOCK_AMOUNT_2);

        vm.prank(user);
        vm.expectRevert();
        BlackholeVotingEscrowFacet(portfolioAccount).merge(tokenA, tokenB);
    }
}
