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
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/BlackholeVotingEscrowFacet.sol";
import {RewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {BlackholeRewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/BlackholeRewardsProcessingFacet.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVotingEscrow as IBlackholeVE} from "../../../../src/Blackhole/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {ILendingPool} from "../../../../src/interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SwapMod} from "../../../../src/facets/account/swap/SwapMod.sol";

interface IVeNFTEnumerable {
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

contract MockLendingPoolSN is ILendingPool {
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
 * @title LiveSuperNovaE2E
 * @dev Fork test against Ethereum mainnet that deploys SuperNova facets,
 *      creates a veNOVA lock, claims rewards, and processes them without a vault.
 */
contract LiveSuperNovaE2E is Test {
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
    IVoter public voter = IVoter(VOTER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        vm.startPrank(DEPLOYER);

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        // Deploy factory (or use existing)
        address factoryAddr = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("supernova-test")));
        if (factoryAddr == address(0)) {
            vm.startPrank(MULTISIG);
            (portfolioFactory, ) = portfolioManager.deployFactory(keccak256(abi.encodePacked("supernova-test")));
            vm.stopPrank();
        } else {
            portfolioFactory = PortfolioFactory(factoryAddr);
        }
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        // Deploy configs inline (can't use script helper — cheatcodes not forwarded)
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

        // Mock loan contract (no real lending)
        MockLendingPoolSN mockLoan = new MockLendingPoolSN(USDC);
        mockLoan.setPortfolioFactory(address(portfolioFactory));
        portfolioFactoryConfig.setLoanContract(address(mockLoan));

        vm.stopPrank();

        // Link config to factory (requires PM owner)
        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Deploy and register facets (registry owned by multisig on new factories)
        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);

        // Deploy ClaimingFacet (no vault)
        ClaimingFacet claimingFacet = new ClaimingFacet(
            address(portfolioFactory), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR,
            address(loanConfig), address(swapConfig), address(0)
        );
        bytes4[] memory claimSel = new bytes4[](3);
        claimSel[0] = ClaimingFacet.claimFees.selector;
        claimSel[1] = ClaimingFacet.claimRebase.selector;
        claimSel[2] = ClaimingFacet.claimLaunchpadToken.selector;
        facetRegistry.registerFacet(address(claimingFacet), claimSel, "ClaimingFacet");

        // Deploy CollateralFacet
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

        // Deploy VotingEscrowFacet
        BlackholeVotingEscrowFacet veFacet = new BlackholeVotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        bytes4[] memory veSel = new bytes4[](5);
        veSel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        veSel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        veSel[2] = BlackholeVotingEscrowFacet.merge.selector;
        veSel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        veSel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        facetRegistry.registerFacet(address(veFacet), veSel, "VotingEscrowFacet");

        // Deploy RewardsProcessingFacet (no vault, default token = USDC)
        BlackholeRewardsProcessingFacet rpFacet = new BlackholeRewardsProcessingFacet(
            address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(0), USDC
        );
        bytes4[] memory rpSel = new bytes4[](5);
        rpSel[0] = RewardsProcessingFacet.processRewards.selector;
        rpSel[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rpSel[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rpSel[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rpSel[4] = RewardsProcessingFacet.calculateRoutes.selector;
        facetRegistry.registerFacet(address(rpFacet), rpSel, "RewardsProcessingFacet");

        // Deploy RewardsConfigFacet
        RewardsConfigFacet rcFacet = new RewardsConfigFacet(address(portfolioFactory));
        bytes4[] memory rcSel = new bytes4[](7);
        rcSel[0] = RewardsConfigFacet.setRewardsToken.selector;
        rcSel[1] = RewardsConfigFacet.setRecipient.selector;
        rcSel[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rcSel[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rcSel[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rcSel[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rcSel[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        facetRegistry.registerFacet(address(rcFacet), rcSel, "RewardsConfigFacet");

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

    // ── Tests ──

    /// @notice getRewardsToken returns USDC (defaultToken) when vault is address(0)
    function testGetRewardsToken_noVault_returnsUSDC() public view {
        address rewardsToken = RewardsProcessingFacet(portfolioAccount).getRewardsToken();
        assertEq(rewardsToken, USDC, "Default rewards token should be USDC");
    }

    /// @notice Create a veNOVA lock via portfolio and verify collateral is tracked
    function testCreateLockAndAddCollateral() public {
        uint256 lockAmount = 1000 * 1e18;
        deal(SNOVA_TOKEN, user, lockAmount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(portfolioAccount, lockAmount);

        // Create lock via multicall
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, lockAmount, 365 days)
        );

        // Verify collateral
        uint256 collateral = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral, 0, "Should have collateral after lock");
        console.log("Collateral after lock:", collateral);
    }

    /// @notice Claim rebase for a veNOVA lock
    function testClaimRebase() public {
        // Create lock first
        uint256 lockAmount = 1000 * 1e18;
        deal(SNOVA_TOKEN, user, lockAmount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(portfolioAccount, lockAmount);
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, lockAmount, 365 days)
        );

        // Get the tokenId
        uint256 tokenId = ve.tokenOfOwnerByIndex(portfolioAccount, 0);
        assertGt(tokenId, 0, "Should have a veNFT");

        // Warp to accrue rebase
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400);

        // Check claimable rebase
        uint256 claimable = IRewardsDistributor(REWARDS_DISTRIBUTOR).claimable(tokenId);
        console.log("Claimable rebase:", claimable);

        // Claim rebase via authorized caller
        vm.prank(authorizedCaller);
        ClaimingFacet(portfolioAccount).claimRebase(tokenId);
    }

    /// @notice Process rewards without a vault — funds should go to recipient
    function testProcessRewards_noVault_noDebt_fundsToRecipient() public {
        // Create lock for collateral
        uint256 lockAmount = 1000 * 1e18;
        deal(SNOVA_TOKEN, user, lockAmount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(portfolioAccount, lockAmount);
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, lockAmount, 365 days)
        );

        // Deal USDC to portfolio as "rewards"
        uint256 rewardsAmount = 100 * 1e6; // 100 USDC
        deal(USDC, portfolioAccount, rewardsAmount);

        // No debt, so all rewards go to recipient (owner by default)
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(user);

        // Get tokenId
        uint256 tokenId = ve.tokenOfOwnerByIndex(portfolioAccount, 0);

        // Process rewards as authorized caller
        SwapMod.RouteParams[4] memory emptySwaps;
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(tokenId, rewardsAmount, emptySwaps, 0);

        uint256 userUsdcAfter = IERC20(USDC).balanceOf(user);
        uint256 received = userUsdcAfter - userUsdcBefore;
        assertGt(received, 0, "User should receive rewards");
        console.log("User received USDC:", received);
        console.log("Zero-balance fee taken:", rewardsAmount - received);
    }

    /// @notice Process rewards with gas reclamation — caller gets capped gas amount
    function testProcessRewards_noVault_withGasReclamation() public {
        uint256 lockAmount = 1000 * 1e18;
        deal(SNOVA_TOKEN, user, lockAmount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(portfolioAccount, lockAmount);
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, lockAmount, 365 days)
        );

        uint256 rewardsAmount = 100 * 1e6;
        deal(USDC, portfolioAccount, rewardsAmount);

        uint256 tokenId = ve.tokenOfOwnerByIndex(portfolioAccount, 0);
        uint256 gasReclamation = 2 * 1e6; // 2 USDC for gas

        uint256 callerBefore = IERC20(USDC).balanceOf(authorizedCaller);
        uint256 userBefore = IERC20(USDC).balanceOf(user);

        SwapMod.RouteParams[4] memory emptySwaps;
        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(tokenId, rewardsAmount, emptySwaps, gasReclamation);

        uint256 callerReceived = IERC20(USDC).balanceOf(authorizedCaller) - callerBefore;
        uint256 userReceived = IERC20(USDC).balanceOf(user) - userBefore;

        assertGt(callerReceived, 0, "Caller should receive gas reclamation");
        assertLe(callerReceived, rewardsAmount * 5 / 100, "Gas reclamation capped at 5%");
        assertGt(userReceived, 0, "User should receive remaining rewards");
        console.log("Gas reclamation:", callerReceived);
        console.log("User received:", userReceived);
    }

    /// @notice Verify no debt is tracked (no vault = no lending)
    function testNoDebt_noVault() public view {
        uint256 debt = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, 0, "Should have zero debt without vault");
    }

    // ── Merge Tests ──

    /// @notice mergeInternal: merge two account-owned tokens, verify VE amounts combine
    function testMergeInternal_happyPath() public {
        uint256 tokenIdA = _createLockInAccount(100e18);
        uint256 tokenIdB = _createLockInAccount(200e18);

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdA), portfolioAccount, "A in account");
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdB), portfolioAccount, "B in account");

        IBlackholeVE.LockedBalance memory lockedA = IBlackholeVE(VOTING_ESCROW).locked(tokenIdA);
        IBlackholeVE.LockedBalance memory lockedB = IBlackholeVE(VOTING_ESCROW).locked(tokenIdB);
        uint256 rawA = uint256(uint128(lockedA.amount));
        uint256 rawB = uint256(uint128(lockedB.amount));

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        console.log("rawA:", rawA, "rawB:", rawB);
        console.log("totalCollateral:", collateralBefore);

        // Merge A into B
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        // fromToken should be burned
        address ownerA = IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdA);
        assertTrue(ownerA == address(0) || ownerA != portfolioAccount, "A should be burned");

        // VE locked amount combined
        IBlackholeVE.LockedBalance memory merged = IBlackholeVE(VOTING_ESCROW).locked(tokenIdB);
        uint256 mergedRaw = uint256(uint128(merged.amount));
        console.log("mergedRaw:", mergedRaw);
        assertEq(mergedRaw, rawA + rawB, "Merged should have combined locked amount");

        // Collateral preserved
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "Total collateral preserved");
        assertEq(BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA), 0, "A collateral zeroed");
        assertEq(BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB), collateralAfter, "B holds all");
    }

    /// @notice external merge: user merges their own veNFT into account's veNFT
    function testMerge_externalHappyPath() public {
        uint256 accountToken = _createLockInAccount(100e18);
        uint256 externalToken = _createExternalLock(200e18);

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(accountToken), portfolioAccount, "Account token in account");
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(externalToken), user, "External token owned by user");

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        IBlackholeVE.LockedBalance memory lockedAcc = IBlackholeVE(VOTING_ESCROW).locked(accountToken);
        IBlackholeVE.LockedBalance memory lockedExt = IBlackholeVE(VOTING_ESCROW).locked(externalToken);
        uint256 rawAcc = uint256(uint128(lockedAcc.amount));
        uint256 rawExt = uint256(uint128(lockedExt.amount));
        console.log("account locked:", rawAcc, "external locked:", rawExt);

        // User approves portfolio account to transfer their token
        vm.prank(user);
        IERC721(VOTING_ESCROW).approve(portfolioAccount, externalToken);

        // User calls merge directly on portfolio account
        vm.prank(user);
        BlackholeVotingEscrowFacet(portfolioAccount).merge(externalToken, accountToken);

        // External token burned
        address extOwner = IVotingEscrow(VOTING_ESCROW).ownerOf(externalToken);
        assertTrue(extOwner == address(0) || extOwner != user, "External token should be burned");

        // VE locked amount combined (SM NFT bonus applies to total, so merged > rawAcc + rawExt)
        IBlackholeVE.LockedBalance memory merged = IBlackholeVE(VOTING_ESCROW).locked(accountToken);
        uint256 mergedRaw = uint256(uint128(merged.amount));
        console.log("merged locked:", mergedRaw);
        assertGe(mergedRaw, rawAcc + rawExt, "Merged should be at least the sum (SM boost may increase it)");

        // Collateral updated
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        console.log("collateral before:", collateralBefore, "after:", collateralAfter);
        assertGt(collateralAfter, collateralBefore, "Collateral should increase");
    }

    /// @notice external merge: revert when fromToken is already in account
    function testMerge_revertFromTokenInAccount() public {
        uint256 tokenA = _createLockInAccount(100e18);
        uint256 tokenB = _createLockInAccount(200e18);

        vm.prank(user);
        vm.expectRevert();
        BlackholeVotingEscrowFacet(portfolioAccount).merge(tokenA, tokenB);
    }

    /// @notice mergeInternal: revert when same token
    function testMergeInternal_revertSameToken() public {
        uint256 tokenId = _createLockInAccount(100e18);

        vm.expectRevert("SameNFT");
        _singleMulticall(
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.mergeInternal.selector, tokenId, tokenId)
        );
    }
}
