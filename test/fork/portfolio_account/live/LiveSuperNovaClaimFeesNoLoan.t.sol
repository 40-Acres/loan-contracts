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
import {BlackholeClaimingFacet} from "../../../../src/facets/account/claim/BlackholeClaimingFacet.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/BlackholeVotingEscrowFacet.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {IGaugeManager} from "../../../../src/Blackhole/interfaces/IGaugeManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISuperNovaVoter {
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;
    function lastVoted(uint256 id) external view returns (uint256);
    function poolVoteLength(uint256 id) external view returns (uint256);
}

interface IBribe {
    function rewardsListLength() external view returns (uint256);
    function bribeTokens(uint256 i) external view returns (address);
}

/**
 * @title LiveSuperNovaClaimFeesNoLoan
 * @dev Sibling to LiveSuperNovaClaimFees. Same scenario (SuperNova with no loanContract),
 *      but every test asserts `getLoanContract() == address(0)` as an explicit precondition
 *      so the no-loan property is an invariant of the suite rather than incidental.
 *
 *      Run: FOUNDRY_PROFILE=fork forge test \
 *             --match-path test/fork/portfolio_account/live/LiveSuperNovaClaimFeesNoLoan.t.sol -vv
 */
contract LiveSuperNovaClaimFeesNoLoan is Test {
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant GAUGE_MANAGER = 0x19a410046Afc4203AEcE5fbFc7A6Ac1a4F517AE2;
    address public constant REWARDS_DISTRIBUTOR = 0xB3410A30af5033aF822B8eA5Ad3bd0a19490ea97;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    address public constant POOL_0 = 0x20F1E9b44FC066191ec08D98517390674b25ffB9;
    bytes4 public constant VOTER_CLAIM_FEES_SELECTOR = 0x666256aa;
    uint256 public constant WEEK = 7 days;

    address public user = address(0x40ac2e);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    VotingConfig public votingConfig;
    LoanConfig public loanConfig;
    SwapConfig public swapConfig;

    address public portfolioAccount;

    ISuperNovaVoter public voter = ISuperNovaVoter(VOTER);
    IGaugeManager public gaugeManager = IGaugeManager(GAUGE_MANAGER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("supernova-claim-fees-noloan-test"))
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
        // loanContract intentionally NOT set.

        address[] memory pools = new address[](1);
        pools[0] = POOL_0;
        votingConfig.setApprovedPools(pools, true);

        vm.stopPrank();

        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);
        _registerCollateralFacet();
        _registerVotingEscrowFacet();
        _registerVotingFacet();
        _registerBlackholeClaimingFacet();
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
        assertEq(
            portfolioFactoryConfig.getLoanContract(),
            address(0),
            "invariant: loanContract must remain address(0)"
        );
    }

    // ── Facet registration ──

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
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        sel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        sel[2] = BlackholeVotingEscrowFacet.merge.selector;
        sel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        sel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        sel[5] = BlackholeVotingEscrowFacet.reset.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingEscrowFacet");
    }

    function _registerVotingFacet() internal {
        VotingFacet facet = new VotingFacet(
            address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER
        );
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = VotingFacet.vote.selector;
        sel[1] = VotingFacet.setVotingMode.selector;
        sel[2] = VotingFacet.isManualVoting.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingFacet");
    }

    function _registerBlackholeClaimingFacet() internal {
        BlackholeClaimingFacet facet = new BlackholeClaimingFacet(
            address(portfolioFactory),
            VOTING_ESCROW,
            VOTER,
            GAUGE_MANAGER,
            REWARDS_DISTRIBUTOR,
            address(0),
            address(loanConfig),
            address(swapConfig),
            address(0)
        );
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = ClaimingFacet.claimFees.selector;
        sel[1] = ClaimingFacet.claimRebase.selector;
        sel[2] = ClaimingFacet.claimLaunchpadToken.selector;
        facetRegistry.registerFacet(address(facet), sel, "ClaimingFacet");
    }

    // ── Helpers ──

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

    function _buildBribeArgs(address pool)
        internal
        view
        returns (address[] memory fees, address[][] memory tokens)
    {
        address gauge = gaugeManager.gauges(pool);
        require(gauge != address(0), "no gauge for pool");
        address internalBribe = gaugeManager.internal_bribes(gauge);
        require(internalBribe != address(0), "no internal bribe");

        fees = new address[](1);
        fees[0] = internalBribe;

        uint256 rewardsLen = IBribe(internalBribe).rewardsListLength();
        address[] memory bribeTokens = new address[](rewardsLen);
        for (uint256 i = 0; i < rewardsLen; i++) {
            bribeTokens[i] = IBribe(internalBribe).bribeTokens(i);
        }
        tokens = new address[][](1);
        tokens[0] = bribeTokens;
    }

    function _votePools() internal pure returns (address[] memory pools, uint256[] memory weights) {
        pools = new address[](1);
        pools[0] = POOL_0;
        weights = new uint256[](1);
        weights[0] = 100;
    }

    // ── Tests ──

    /// @notice Regression guard: old voter.claimFees selector still reverts on SuperNova.
    function testVoterClaimFees_oldPath_reverts_noLoan() public {
        _assertNoLoan();
        address[] memory emptyFees = new address[](0);
        address[][] memory emptyTokens = new address[][](0);
        (bool ok, ) = VOTER.call(
            abi.encodeWithSelector(VOTER_CLAIM_FEES_SELECTOR, emptyFees, emptyTokens, 1)
        );
        assertFalse(ok, "voter.claimFees must NOT succeed on SuperNova");
    }

    /// @notice claimFees with empty arrays succeeds with no loan contract.
    function testClaimFees_emptyArgs_succeeds_noLoan() public {
        _assertNoLoan();
        uint256 tokenId = _createLockInAccount(1000e18);
        address[] memory fees = new address[](0);
        address[][] memory tokens = new address[][](0);
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);
        assertGt(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "collateral tracked post-claim"
        );
    }

    /// @notice Happy path — vote, warp epoch, claimFees routes via GaugeManager.
    function testClaimFees_happyPath_viaGaugeManager_noLoan() public {
        _assertNoLoan();
        vm.warp(((block.timestamp / WEEK) * WEEK) + WEEK + 2 hours);

        uint256 tokenId = _createLockInAccount(1000e18);

        (address[] memory pools, uint256[] memory weights) = _votePools();
        _singleMulticall(
            user,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        assertGt(voter.lastVoted(tokenId), 0, "vote landed");

        vm.warp(block.timestamp + WEEK + 1 hours);

        (address[] memory fees, address[][] memory tokens) = _buildBribeArgs(POOL_0);
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);

        assertGt(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "collateral tracked post-claim"
        );
    }

    /// @notice claimFees triggers rebase claim with single distributor; no-loan invariant holds.
    function testClaimFees_triggersRebase_singleDistributor_noLoan() public {
        _assertNoLoan();
        uint256 tokenId = _createLockInAccount(1000e18);

        vm.warp(block.timestamp + 2 weeks);
        vm.roll(block.number + 1);

        uint256 claimableBefore = IRewardsDistributor(REWARDS_DISTRIBUTOR).claimable(tokenId);

        address[] memory fees = new address[](0);
        address[][] memory tokens = new address[][](0);

        if (claimableBefore > 0) {
            vm.expectEmit(true, false, false, false, portfolioAccount);
            emit ClaimingFacet.RebaseClaimed(tokenId, claimableBefore);
        }
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);

        if (claimableBefore > 0) {
            assertEq(IRewardsDistributor(REWARDS_DISTRIBUTOR).claimable(tokenId), 0, "rebase claimed");
        }
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), portfolioAccount, "veNFT retained");
    }

    /// @notice Routing proof — claimFees revert must come from GaugeManager, not voter.
    function testClaimFees_routesToGaugeManager_notVoter_noLoan() public {
        _assertNoLoan();
        uint256 tokenId = _createLockInAccount(1000e18);

        address[] memory fees = new address[](1);
        fees[0] = address(0xBEEF);
        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](1);
        tokens[0][0] = SNOVA_TOKEN;

        vm.mockCallRevert(
            GAUGE_MANAGER,
            abi.encodeWithSelector(IGaugeManager.claimBribes.selector, fees, tokens, tokenId),
            abi.encodeWithSignature("Error(string)", "GM_CLAIM_BRIBES_HIT")
        );
        vm.mockCallRevert(
            VOTER,
            abi.encodeWithSelector(VOTER_CLAIM_FEES_SELECTOR, fees, tokens, tokenId),
            abi.encodeWithSignature("Error(string)", "VOTER_CLAIM_FEES_HIT")
        );

        vm.expectRevert(bytes("GM_CLAIM_BRIBES_HIT"));
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);

        vm.clearMockedCalls();
    }
}
