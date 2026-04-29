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
import {BlackholeClaimingFacet} from "../../../../src/facets/account/blackhole/BlackholeClaimingFacet.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";
import {RewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {BlackholeRewardsProcessingFacet} from "../../../../src/facets/account/blackhole/BlackholeRewardsProcessingFacet.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IVeNFTEnumerable {
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
}

/**
 * @title LiveSuperNovaE2ENoLoan
 * @dev Fork test verifying the full SuperNova flow works with NO loan contract and NO vault.
 *      Exists specifically as a regression canary for the `getRewardsToken()` bug
 *      (previously `require(loanContract != address(0))` broke no-loan deployments).
 *
 *      Difference from LiveSuperNovaE2E: no MockLendingPool, no setLoanContract,
 *      and every test asserts `getLoanContract() == address(0)` as a precondition.
 *
 *      Run: FOUNDRY_PROFILE=fork forge test \
 *             --match-path test/fork/portfolio_account/live/LiveSuperNovaE2ENoLoan.t.sol -vv
 */
contract LiveSuperNovaE2ENoLoan is Test {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44; // veNOVA
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant GAUGE_MANAGER = 0x19a410046Afc4203AEcE5fbFc7A6Ac1a4F517AE2;
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
    VotingConfig public votingConfig;
    SwapConfig public swapConfig;

    address public portfolioAccount;

    IVeNFTEnumerable public ve = IVeNFTEnumerable(VOTING_ESCROW);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("supernova-e2e-noloan-test"))
        );
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        portfolioFactoryConfig = PortfolioFactoryConfig(address(new ERC1967Proxy(
            address(new PortfolioFactoryConfig()),
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER, address(portfolioFactory)))
        )));
        votingConfig = VotingConfig(address(new ERC1967Proxy(
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
        // NOTE: loanContract intentionally NOT set — this is the no-loan scenario.

        vm.stopPrank();

        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);
        _registerCollateralFacet();
        _registerVotingEscrowFacet();
        _registerClaimingFacet();
        _registerRewardsProcessingFacet();
        _registerRewardsConfigFacet();
        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
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

    // ── Facet Registration ──

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
        BlackholeVotingEscrowFacet facet = new BlackholeVotingEscrowFacet(
            address(portfolioFactory), VOTING_ESCROW, VOTER
        );
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        sel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        sel[2] = BlackholeVotingEscrowFacet.merge.selector;
        sel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        sel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingEscrowFacet");
    }

    function _registerClaimingFacet() internal {
        // SuperNova: pass address(0) for vault; loanConfig IS set (fee rates).
        BlackholeClaimingFacet facet = new BlackholeClaimingFacet(
            address(portfolioFactory),
            VOTING_ESCROW,
            VOTER,
            GAUGE_MANAGER,
            REWARDS_DISTRIBUTOR,
            address(0),           // secondary rewards distributor — SuperNova has one
            address(loanConfig),
            address(swapConfig),
            address(0)            // vault
        );
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = ClaimingFacet.claimFees.selector;
        sel[1] = ClaimingFacet.claimRebase.selector;
        sel[2] = ClaimingFacet.claimLaunchpadToken.selector;
        facetRegistry.registerFacet(address(facet), sel, "ClaimingFacet");
    }

    function _registerRewardsProcessingFacet() internal {
        // vault = address(0), underlyingLockedAsset routed as defaultToken = USDC.
        BlackholeRewardsProcessingFacet facet = new BlackholeRewardsProcessingFacet(
            address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(0), USDC
        );
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = RewardsProcessingFacet.processRewards.selector;
        sel[1] = RewardsProcessingFacet.getRewardsToken.selector;
        sel[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        sel[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        sel[4] = RewardsProcessingFacet.calculateRoutes.selector;
        facetRegistry.registerFacet(address(facet), sel, "RewardsProcessingFacet");
    }

    function _registerRewardsConfigFacet() internal {
        RewardsConfigFacet facet = new RewardsConfigFacet(address(portfolioFactory));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = RewardsConfigFacet.setRecipient.selector;
        sel[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        sel[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        sel[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        sel[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        sel[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        facetRegistry.registerFacet(address(facet), sel, "RewardsConfigFacet");
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

    // ── Tests ──

    /// @notice PRIMARY REGRESSION CANARY.
    /// getRewardsToken() must NOT revert when loanContract is address(0).
    /// The old `require(loanContract != address(0))` would have reverted this call.
    function testGetRewardsToken_returnsUSDC_regressionCanary() public view {
        assertEq(portfolioFactoryConfig.getLoanContract(), address(0), "precondition: no loan");
        address rewardsToken = RewardsProcessingFacet(portfolioAccount).getRewardsToken();
        assertEq(rewardsToken, USDC, "should fall back to defaultToken (USDC) with no vault & no debt");
    }

    /// @notice Create lock and verify collateral tracking works with no loan contract.
    function testCreateLockAddCollateral_noLoan() public {
        uint256 tokenId = _createLockInAccount(1000e18);

        uint256 collateral = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral, 0, "collateral should be tracked");

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "maxLoan must be 0 without loan contract");
        assertEq(maxLoanIgnoreSupply, 0, "maxLoanIgnoreSupply must be 0 without loan contract");

        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), 0, "debt must be 0");
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), portfolioAccount, "veNFT owned by account");
    }

    /// @notice claimRebase succeeds with no loan contract. Any claimable is consumed.
    function testClaimRebase_noLoan() public {
        uint256 tokenId = _createLockInAccount(1000e18);

        vm.warp(block.timestamp + 2 weeks);
        vm.roll(block.number + 1);

        uint256 claimableBefore = IRewardsDistributor(REWARDS_DISTRIBUTOR).claimable(tokenId);
        console.log("claimable before:", claimableBefore);

        vm.prank(authorizedCaller);
        ClaimingFacet(portfolioAccount).claimRebase(tokenId);

        if (claimableBefore > 0) {
            assertEq(
                IRewardsDistributor(REWARDS_DISTRIBUTOR).claimable(tokenId),
                0,
                "rebase should be fully claimed"
            );
        }
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), portfolioAccount, "veNFT stays in account");
    }

    /// @notice removeCollateral succeeds with no debt and no loanContract.
    function testRemoveCollateral_noLoan_noDebt() public {
        uint256 tokenId = _createLockInAccount(1000e18);
        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "setup: should have collateral");

        _singleMulticall(abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId));

        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "collateral should be zeroed"
        );
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            user,
            "veNFT returned to user"
        );
    }
}
