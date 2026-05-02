// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVotingEscrow as IBlackholeVE} from "../../../../src/Blackhole/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ISuperNovaVoter {
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;
    function reset(uint256 _tokenId) external;
    function lastVoted(uint256 id) external view returns (uint256);
    function poolVoteLength(uint256 id) external view returns (uint256);
    function poolVote(uint256 id, uint256 _index) external view returns (address);
    function votes(uint256 id, address _pool) external view returns (uint256);
    function gauges(address pool) external view returns (address);
    function isAlive(address gauge) external view returns (bool);
}

/**
 * @title LiveSuperNovaVoteWithdraw
 * @dev Fork test against Ethereum mainnet verifying veNOVA deposit/withdraw flows
 *      around the Solidly-style "token attached to voter" restriction.
 *
 *  Users who vote through the portfolio must call BlackholeVotingEscrowFacet.reset
 *  before removeCollateral (bundled in one multicall is fine). Same-epoch reset
 *  reverts — that restriction comes from the underlying voter.
 *
 * Run: FOUNDRY_PROFILE=fork forge test --match-contract LiveSuperNovaVoteWithdraw --rpc-url $ETH_RPC_URL -vvvv
 */
contract LiveSuperNovaVoteWithdraw is Test {
    // SuperNova / Ethereum Mainnet addresses
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // Known-approved / live SuperNova pools (reused from LiveSuperNovaClaim1148)
    address public constant POOL_0 = 0x20F1E9b44FC066191ec08D98517390674b25ffB9;
    address public constant POOL_1 = 0x694736a70D63241884e891fd0416B1Ada7ff2bDB;
    address public constant POOL_2 = 0x6ac7f10Cdb07C564D2FE95e9b4a586780c5A0278;

    uint256 public constant WEEK = 7 days;

    address public user = address(0x40ac2e);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    VotingConfig public votingConfig;

    address public portfolioAccount;

    ISuperNovaVoter public voter = ISuperNovaVoter(VOTER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("supernova-vote-withdraw-test"))
        );
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        portfolioFactoryConfig = PortfolioFactoryConfig(address(new ERC1967Proxy(
            address(new PortfolioFactoryConfig()),
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER, address(portfolioFactory)))
        )));

        // VotingConfig is a standalone proxy owned by DEPLOYER.
        votingConfig = VotingConfig(address(new ERC1967Proxy(
            address(new VotingConfig()),
            abi.encodeCall(VotingConfig.initialize, (DEPLOYER))
        )));

        address[] memory pools = new address[](3);
        pools[0] = POOL_0;
        pools[1] = POOL_1;
        pools[2] = POOL_2;
        votingConfig.setApprovedPools(pools, true);

        vm.stopPrank();

        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);

        _registerCollateralFacet();
        _registerVotingEscrowFacet();
        _registerVotingFacet();

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        // Advance a second so that block.timestamp > origin, avoids edge cases
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
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
        sel[10] = BaseCollateralFacet.getLoanUtilization.selector;
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
            address(portfolioFactory),
            address(votingConfig),
            VOTING_ESCROW,
            VOTER
        );
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = VotingFacet.vote.selector;
        sel[1] = VotingFacet.setVotingMode.selector;
        sel[2] = VotingFacet.isManualVoting.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingFacet");
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

    function _votePools() internal pure returns (address[] memory pools, uint256[] memory weights) {
        pools = new address[](1);
        pools[0] = POOL_0;
        weights = new uint256[](1);
        weights[0] = 100;
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 1: deposit and withdraw, no vote — control case
    // ─────────────────────────────────────────────────────────────────

    /// @notice Deposit then immediately withdraw when no vote has happened.
    ///         veNFT returns to user, collateral balance goes to 0.
    function testDepositAndWithdraw_noVote() public {
        uint256 tokenId = _createLockInAccount(1000e18);

        // Collateral tracked
        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "collateral tracked after createLock");
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            portfolioAccount,
            "portfolio owns veNFT"
        );

        // No vote ever happened on this freshly-minted token
        assertEq(voter.lastVoted(tokenId), 0, "token has never voted");

        // Withdraw — no attach, no reset required
        _singleMulticall(
            user,
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, 0, "collateral zero after removeCollateral");
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            user,
            "veNFT returned to user"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 2: token voted outside the portfolio can't be used until
    //         next epoch (reset), then deposit flow works.
    // ─────────────────────────────────────────────────────────────────

    /// @notice User holds a freshly-voted veNOVA OUTSIDE the portfolio. Because the
    ///         token voted in the current epoch, any action that would require the
    ///         token to be reset-then-moved in the same epoch is blocked. After
    ///         warping to next epoch the user can reset and then deposit into the
    ///         portfolio and vote successfully.
    ///
    ///         Phrased to match the scenario description:
    ///         "user votes but can't deposit because it can't reset, then next
    ///          epoch resets then deposits."
    function testVoteBlocksDeposit_thenResetsNextEpoch() public {
        // 1. Mint veNOVA to `user` directly (NOT through portfolio)
        uint256 amount = 1000e18;
        deal(SNOVA_TOKEN, user, amount);
        vm.startPrank(user);
        IERC20(SNOVA_TOKEN).approve(VOTING_ESCROW, amount);
        uint256 tokenId = IBlackholeVE(VOTING_ESCROW).create_lock_for(
            amount, 4 * 365 days, user, true
        );
        vm.stopPrank();

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), user, "user owns token");

        // 2. User votes in THIS epoch via the voter directly.
        (address[] memory pools, uint256[] memory weights) = _votePools();
        // Voter typically disallows voting at the very start of an epoch (distribute
        // window). Warp forward to NEXT epoch's vote start to safely pass
        // `epochVoteStart`. Always advance forward.
        vm.warp(((block.timestamp / WEEK) * WEEK) + WEEK + 1 hours + 1);
        vm.prank(user);
        voter.vote(tokenId, pools, weights);

        // Note: don't compare to `block.timestamp` directly — via-ir caches
        // block.timestamp across vm.warp and the compare silently mismatches.
        // Instead assert vote produced an attachment.
        uint256 lastVotedAfterDirect = voter.lastVoted(tokenId);
        assertGt(lastVotedAfterDirect, 0, "lastVoted set");
        assertGt(voter.poolVoteLength(tokenId), 0, "token attached after vote");

        // 3. Attempting to reset in the SAME epoch reverts — Solidly voters forbid
        //    reset once lastVoted == current epoch.
        vm.prank(user);
        vm.expectRevert();
        voter.reset(tokenId);

        // 4. Also confirm that if the user transferred the NFT into a portfolio
        //    account the portfolio could not reset+withdraw either (same attach
        //    constraint). We don't actually transfer because transferFrom of an
        //    attached token also reverts on Solidly-style voters; we just assert
        //    the attached state persists until epoch boundary.
        assertGt(voter.poolVoteLength(tokenId), 0, "token is attached to pools");

        // 5. Warp to next epoch. Reset is now permitted.
        vm.warp(block.timestamp + WEEK);
        vm.prank(user);
        voter.reset(tokenId);
        assertEq(voter.poolVoteLength(tokenId), 0, "reset cleared pool votes");

        // 6. User can now safely transfer into their portfolio and add as collateral.
        vm.prank(user);
        IERC721(VOTING_ESCROW).approve(portfolioAccount, tokenId);
        _singleMulticall(
            user,
            abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId)
        );
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            portfolioAccount,
            "portfolio now owns token"
        );
        assertGt(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "collateral tracked"
        );

        // 7. And can vote through the portfolio in this new epoch.
        _singleMulticall(
            user,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        // Assert the second (portfolio-mediated) vote advanced lastVoted past the
        // earlier direct vote timestamp. Using a delta check avoids the via-ir
        // `block.timestamp` cache problem; and using lastVoted (not
        // poolVoteLength) avoids any same-tx view inconsistency.
        uint256 lastVotedAfterPortfolio = voter.lastVoted(tokenId);
        assertGt(
            lastVotedAfterPortfolio,
            lastVotedAfterDirect,
            "portfolio vote advanced lastVoted"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 3: deposit, vote inside portfolio, removeCollateral must
    //         revert same epoch, and SHOULD succeed next epoch.
    // ─────────────────────────────────────────────────────────────────

    /// @notice Deposit into portfolio, vote through VotingFacet, then try to withdraw:
    ///         - same epoch: removeCollateral reverts (token still attached, reset
    ///           not yet callable)
    ///         - next epoch: user bundles [reset, removeCollateral] into a single
    ///           multicall and the withdraw succeeds.
    function testVoteInsidePortfolio_withdrawBlocked_thenNextEpoch() public {
        // Position us well inside an epoch before creating the lock so subsequent
        // vote() calls don't land in the distribute window. Always advance forward
        // — never warp backward (breaks VE checkpoint iteration under via-ir).
        vm.warp(((block.timestamp / WEEK) * WEEK) + WEEK + 2 hours);

        uint256 tokenId = _createLockInAccount(1000e18);
        (address[] memory pools, uint256[] memory weights) = _votePools();

        // Vote through VotingFacet in the same epoch as deposit
        _singleMulticall(
            user,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        // Avoid comparing against block.timestamp (via-ir caching).
        assertGt(voter.lastVoted(tokenId), 0, "lastVoted set via portfolio");
        assertGt(voter.poolVoteLength(tokenId), 0, "token attached after vote");

        // Attempt to withdraw in same epoch — must revert.
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        vm.prank(user);
        vm.expectRevert();
        portfolioManager.multicall(calldatas, factories);

        // Portfolio still owns token, still attached.
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            portfolioAccount,
            "portfolio still owns token"
        );
        assertGt(voter.poolVoteLength(tokenId), 0, "still attached same epoch");

        // Warp one week forward — we're now in a fresh epoch and reset is allowed.
        vm.warp(block.timestamp + WEEK);

        // Bundle [reset, removeCollateral] in one multicall — reset clears the
        // voter attachment so safeTransferFrom can succeed.
        bytes[] memory withdrawCalls = new bytes[](2);
        withdrawCalls[0] = abi.encodeWithSelector(BlackholeVotingEscrowFacet.reset.selector, tokenId);
        withdrawCalls[1] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        _multicallAs(user, withdrawCalls);

        // Post-conditions expressing intended behaviour
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            user,
            "veNFT should be returned to user after withdraw next epoch"
        );
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "collateral should be zero after withdraw"
        );
        assertEq(voter.poolVoteLength(tokenId), 0, "withdraw flow should have reset votes");
    }
}
