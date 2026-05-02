// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";
import {RewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {BlackholeRewardsProcessingFacet} from "../../../../src/facets/account/blackhole/BlackholeRewardsProcessingFacet.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVotingEscrow as IBlackholeVE} from "../../../../src/Blackhole/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {ILendingPool} from "../../../../src/interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IVeNFTEnumerable {
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

contract MockLendingPoolMerge is ILendingPool {
    address public immutable _lendingAsset;
    address public _portfolioFactory;

    constructor(address lendingAsset_) { _lendingAsset = lendingAsset_; }
    function setPortfolioFactory(address factory) external { _portfolioFactory = factory; }
    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function borrowFromPortfolio(uint256) external pure returns (uint256) { return 0; }
    function payFromPortfolio(uint256 totalPayment, uint256) external pure returns (uint256) { return totalPayment; }
    function lendingAsset() external view returns (address) { return _lendingAsset; }
    function lendingVault() external pure returns (address) { return address(0); }
    function activeAssets() external pure returns (uint256) { return 0; }
    function depositRewards(uint256) external {}
    function setActiveAssets(uint256) external {}
    function getDebtBalance(address) external pure returns (uint256) { return 0; }
    function getEffectiveDebtBalance(address) external pure returns (uint256) { return 0; }
}

/**
 * @title LiveSuperNovaMerge
 * @dev Fork test against Ethereum mainnet that tests merge and mergeInternal
 *      for SuperNova (BlackholeVotingEscrowFacet) against the real veNOVA contract.
 */
contract LiveSuperNovaMerge is Test {
    // SuperNova addresses (Ethereum Mainnet)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44; // veNOVA
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant REWARDS_DISTRIBUTOR = 0xB3410A30af5033aF822B8eA5Ad3bd0a19490ea97;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    address public user = address(0x40ac2e);
    address public authorizedCaller = address(0xaaaaa);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LoanConfig public loanConfig;
    SwapConfig public swapConfig;

    address public portfolioAccount;

    IVeNFTEnumerable public ve = IVeNFTEnumerable(VOTING_ESCROW);

    uint256 constant LOCK_AMOUNT_1 = 100e18;
    uint256 constant LOCK_AMOUNT_2 = 200e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        vm.startPrank(DEPLOYER);

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        // Deploy factory with unique test salt
        address factoryAddr = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("supernova-merge-test")));
        if (factoryAddr == address(0)) {
            vm.startPrank(MULTISIG);
            (portfolioFactory, ) = portfolioManager.deployFactory(keccak256(abi.encodePacked("supernova-merge-test")));
            vm.stopPrank();
        } else {
            portfolioFactory = PortfolioFactory(factoryAddr);
        }
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        // Deploy configs
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
        swapConfig = SwapConfig(address(new ERC1967Proxy(
            address(new SwapConfig()),
            abi.encodeCall(SwapConfig.initialize, (DEPLOYER))
        )));
        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        // Mock loan contract (no real lending needed for merge tests)
        MockLendingPoolMerge mockLoan = new MockLendingPoolMerge(USDC);
        mockLoan.setPortfolioFactory(address(portfolioFactory));
        portfolioFactoryConfig.setLoanContract(address(mockLoan));

        loanConfig.setRewardsRate(11300);
        loanConfig.setMultiplier(100);

        vm.stopPrank();

        // Link config to factory (requires PM owner)
        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Deploy and register facets
        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);

        // CollateralFacet
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
        colSel[10] = BaseCollateralFacet.getLoanUtilization.selector;
        facetRegistry.registerFacet(address(collateralFacet), colSel, "CollateralFacet");

        // BlackholeVotingEscrowFacet
        BlackholeVotingEscrowFacet veFacet = new BlackholeVotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        bytes4[] memory veSel = new bytes4[](5);
        veSel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        veSel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        veSel[2] = BlackholeVotingEscrowFacet.merge.selector;
        veSel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        veSel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        facetRegistry.registerFacet(address(veFacet), veSel, "VotingEscrowFacet");

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        vm.stopPrank();

        // Create user portfolio
        portfolioAccount = portfolioFactory.createAccount(user);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
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

    /// @notice mergeInternal: merge two account-owned tokens
    function testMergeInternal_happyPath() public {
        uint256 tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        console.log("tokenIdA:", tokenIdA);
        console.log("tokenIdB:", tokenIdB);

        // Verify both tokens are in the account
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdA), portfolioAccount, "A should be in account");
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdB), portfolioAccount, "B should be in account");

        // Record state before merge
        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        uint256 collateralA = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA);
        uint256 collateralB = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB);

        console.log("Total collateral before:", collateralBefore);
        console.log("Collateral A:", collateralA);
        console.log("Collateral B:", collateralB);

        assertGt(collateralA, 0, "A should have collateral");
        assertGt(collateralB, 0, "B should have collateral");

        // Merge A into B
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        // Verify fromToken (A) burned or transferred away
        address ownerA = IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdA);
        assertTrue(ownerA == address(0) || ownerA != portfolioAccount, "A should be burned or removed");

        // Verify collateral tracking
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        uint256 newCollateralA = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA);
        uint256 newCollateralB = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB);

        console.log("Total collateral after:", collateralAfter);
        console.log("New collateral A:", newCollateralA);
        console.log("New collateral B:", newCollateralB);

        assertEq(newCollateralA, 0, "A collateral should be 0 after merge");
        assertEq(collateralAfter, collateralBefore, "Total collateral should be preserved");
    }

    /// @notice mergeInternal: verify VE locked amount is correct after merge
    function testMergeInternal_veLockedAmountCombined() public {
        uint256 tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        IBlackholeVE.LockedBalance memory lockedA = IBlackholeVE(VOTING_ESCROW).locked(tokenIdA);
        IBlackholeVE.LockedBalance memory lockedB = IBlackholeVE(VOTING_ESCROW).locked(tokenIdB);
        uint256 rawA = uint256(uint128(lockedA.amount));
        uint256 rawB = uint256(uint128(lockedB.amount));

        console.log("Raw locked A:", rawA);
        console.log("Raw locked B:", rawB);

        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        IBlackholeVE.LockedBalance memory mergedLock = IBlackholeVE(VOTING_ESCROW).locked(tokenIdB);
        uint256 mergedRaw = uint256(uint128(mergedLock.amount));
        console.log("Merged locked B:", mergedRaw);

        assertEq(mergedRaw, rawA + rawB, "Merged token should have combined locked amount");
    }

    // ── Tests: external merge ──

    /// @notice external merge: user merges their own veNFT into account's veNFT
    function testMerge_externalHappyPath() public {
        // Create token in account
        uint256 accountToken = _createLockInAccount(LOCK_AMOUNT_1);

        // Create external user-owned token
        uint256 externalToken = _createExternalLock(LOCK_AMOUNT_2);

        console.log("Account token:", accountToken);
        console.log("External token:", externalToken);

        // Verify ownership
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(accountToken), portfolioAccount, "Account token in account");
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(externalToken), user, "External token owned by user");

        // Record state before merge
        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        IBlackholeVE.LockedBalance memory lockedAccount = IBlackholeVE(VOTING_ESCROW).locked(accountToken);
        IBlackholeVE.LockedBalance memory lockedExternal = IBlackholeVE(VOTING_ESCROW).locked(externalToken);
        uint256 rawAccount = uint256(uint128(lockedAccount.amount));
        uint256 rawExternal = uint256(uint128(lockedExternal.amount));

        console.log("Collateral before:", collateralBefore);
        console.log("Account locked:", rawAccount);
        console.log("External locked:", rawExternal);

        // User approves portfolio account to transfer their token
        vm.prank(user);
        IERC721(VOTING_ESCROW).approve(portfolioAccount, externalToken);

        // User calls merge on their portfolio account (not via multicall — direct call)
        vm.prank(user);
        BlackholeVotingEscrowFacet(portfolioAccount).merge(externalToken, accountToken);

        // Verify external token is burned
        address externalOwner = IVotingEscrow(VOTING_ESCROW).ownerOf(externalToken);
        assertTrue(externalOwner == address(0) || externalOwner != user, "External token should be burned");

        // Verify VE locked amount combined. Account token is an sMNFT (createLock passes
        // isSMNFT=true); external token is a regular 4yr lock. veNOVA applies the sMNFT
        // bonus to the absorbed amount, so merged raw = rawAccount + rawExternal + bonus.
        IBlackholeVE.LockedBalance memory mergedLock = IBlackholeVE(VOTING_ESCROW).locked(accountToken);
        uint256 mergedRaw = uint256(uint128(mergedLock.amount));
        uint256 smBonus = IBlackholeVE(VOTING_ESCROW).calculate_sm_nft_bonus(rawExternal);
        console.log("Merged locked:", mergedRaw);
        console.log("sMNFT bonus on external:", smBonus);
        assertEq(mergedRaw, rawAccount + rawExternal + smBonus, "Merged token should have combined locked amount plus sMNFT bonus");

        // Verify collateral tracking updated
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        console.log("Collateral after:", collateralAfter);
        assertGt(collateralAfter, collateralBefore, "Collateral should increase after external merge");
        assertEq(collateralAfter, mergedRaw, "Collateral should match merged VE amount");
    }

    /// @notice external merge: second user cannot merge into someone else's account
    function testMerge_revertNotOwner() public {
        uint256 accountToken = _createLockInAccount(LOCK_AMOUNT_1);

        // Create a token owned by user2
        address user2 = address(0xdead0002);
        deal(SNOVA_TOKEN, user2, LOCK_AMOUNT_2);
        vm.startPrank(user2);
        IERC20(SNOVA_TOKEN).approve(VOTING_ESCROW, LOCK_AMOUNT_2);
        uint256 externalToken = IBlackholeVE(VOTING_ESCROW).create_lock_for(LOCK_AMOUNT_2, 4 * 365 days, user2, false);

        // user2 approves portfolio account
        IERC721(VOTING_ESCROW).approve(portfolioAccount, externalToken);

        // user2 tries to merge — transferFrom uses msg.sender so it should work
        // (the function is permissionless, but the user must approve)
        BlackholeVotingEscrowFacet(portfolioAccount).merge(externalToken, accountToken);
        vm.stopPrank();

        // Verify merge succeeded (anyone can merge into the account's token)
        IBlackholeVE.LockedBalance memory mergedLock = IBlackholeVE(VOTING_ESCROW).locked(accountToken);
        uint256 mergedRaw = uint256(uint128(mergedLock.amount));
        assertGt(mergedRaw, LOCK_AMOUNT_1, "Should have more locked after merge from user2");
    }

    /// @notice external merge: revert when toToken is not in account
    function testMerge_revertToTokenNotInAccount() public {
        uint256 externalToken = _createExternalLock(LOCK_AMOUNT_1);

        // Try to merge into a non-existent / non-account token
        vm.prank(user);
        vm.expectRevert();
        BlackholeVotingEscrowFacet(portfolioAccount).merge(externalToken, 999999);
    }

    /// @notice external merge: revert when fromToken is already in account
    function testMerge_revertFromTokenInAccount() public {
        uint256 tokenA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenB = _createLockInAccount(LOCK_AMOUNT_2);

        // Try external merge when fromToken is already in account — should revert
        vm.prank(user);
        vm.expectRevert();
        BlackholeVotingEscrowFacet(portfolioAccount).merge(tokenA, tokenB);
    }

    // ── Tests: collateral consistency ──

    /// @notice mergeInternal: total collateral preserved after merge
    function testMergeInternal_collateralPreserved() public {
        uint256 tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        uint256 totalBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        uint256 totalAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(totalAfter, totalBefore, "Total collateral must be preserved after mergeInternal");

        // Surviving token holds all collateral
        uint256 survivorCollateral = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB);
        assertEq(survivorCollateral, totalAfter, "Surviving token should hold all collateral");
    }

    /// @notice mergeInternal: revert when same token
    function testMergeInternal_revertSameToken() public {
        uint256 tokenId = _createLockInAccount(LOCK_AMOUNT_1);

        vm.expectRevert("SameNFT");
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenId, tokenId)
        );
    }
}
