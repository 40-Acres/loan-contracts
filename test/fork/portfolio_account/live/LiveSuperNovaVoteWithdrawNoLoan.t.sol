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
}

/**
 * @title LiveSuperNovaVoteWithdrawNoLoan
 * @dev Sibling to LiveSuperNovaVoteWithdraw: SuperNova deployment WITH LoanConfig
 *      (for protocol fee rates) but WITHOUT a loan contract or vault. Verifies that
 *      vote/reset/withdraw flows are identical in the collateral-only deployment.
 */
contract LiveSuperNovaVoteWithdrawNoLoan is Test {
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

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
    LoanConfig public loanConfig;

    address public portfolioAccount;

    ISuperNovaVoter public voter = ISuperNovaVoter(VOTER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("supernova-vote-withdraw-noloan-test"))
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

        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));
        // loanContract intentionally NOT set.

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
            address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER
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

    // ── Tests ──

    /// @notice Control — deposit + immediate withdraw (no vote, no debt, no loan contract).
    function testDepositAndWithdraw_noVote_noLoan() public {
        _assertNoLoan();
        uint256 tokenId = _createLockInAccount(1000e18);

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "collateral tracked");
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), 0, "no debt");
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "maxLoan 0 without loan contract");
        assertEq(maxLoanIgnoreSupply, 0, "maxLoanIgnoreSupply 0 without loan contract");

        _singleMulticall(
            user,
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "zeroed");
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), user, "veNFT returned");
    }

    /// @notice User votes outside the portfolio, same-epoch reset reverts, next-epoch
    ///         reset + deposit + portfolio-vote lifecycle succeeds. No loan contract.
    function testVoteBlocksDeposit_thenResetsNextEpoch_noLoan() public {
        _assertNoLoan();

        uint256 amount = 1000e18;
        deal(SNOVA_TOKEN, user, amount);
        vm.startPrank(user);
        IERC20(SNOVA_TOKEN).approve(VOTING_ESCROW, amount);
        uint256 tokenId = IBlackholeVE(VOTING_ESCROW).create_lock_for(
            amount, 4 * 365 days, user, true
        );
        vm.stopPrank();

        (address[] memory pools, uint256[] memory weights) = _votePools();

        vm.warp(((block.timestamp / WEEK) * WEEK) + WEEK + 1 hours + 1);
        vm.prank(user);
        voter.vote(tokenId, pools, weights);

        uint256 lastVotedAfterDirect = voter.lastVoted(tokenId);
        assertGt(lastVotedAfterDirect, 0, "lastVoted set");
        assertGt(voter.poolVoteLength(tokenId), 0, "attached");

        vm.prank(user);
        vm.expectRevert();
        voter.reset(tokenId);

        vm.warp(block.timestamp + WEEK);
        vm.prank(user);
        voter.reset(tokenId);
        assertEq(voter.poolVoteLength(tokenId), 0, "reset cleared");

        vm.prank(user);
        IERC721(VOTING_ESCROW).approve(portfolioAccount, tokenId);
        _singleMulticall(
            user,
            abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId)
        );
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), portfolioAccount, "portfolio owns");
        assertGt(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "collateral");

        _singleMulticall(
            user,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        assertGt(voter.lastVoted(tokenId), lastVotedAfterDirect, "portfolio vote advanced");
    }

    /// @notice Vote inside portfolio, same-epoch withdraw reverts, next-epoch
    ///         [reset, removeCollateral] multicall succeeds.
    function testVoteInsidePortfolio_withdrawBlocked_thenNextEpoch_noLoan() public {
        _assertNoLoan();
        vm.warp(((block.timestamp / WEEK) * WEEK) + WEEK + 2 hours);

        uint256 tokenId = _createLockInAccount(1000e18);
        (address[] memory pools, uint256[] memory weights) = _votePools();

        _singleMulticall(
            user,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        assertGt(voter.poolVoteLength(tokenId), 0, "attached");

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        vm.prank(user);
        vm.expectRevert();
        portfolioManager.multicall(calldatas, factories);

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), portfolioAccount, "still owned");

        vm.warp(block.timestamp + WEEK);

        bytes[] memory withdrawCalls = new bytes[](2);
        withdrawCalls[0] = abi.encodeWithSelector(BlackholeVotingEscrowFacet.reset.selector, tokenId);
        withdrawCalls[1] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        _multicallAs(user, withdrawCalls);

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), user, "veNFT returned");
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "zeroed");
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), 0, "no debt emerged");
    }
}
