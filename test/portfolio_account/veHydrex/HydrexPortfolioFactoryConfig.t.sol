// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {NFTPortfolioFactoryConfig} from "../../../src/facets/account/config/NFTPortfolioFactoryConfig.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";

/// @dev HydrexPortfolioFactoryConfig tests. Mocks define the receiver hook
///      writer path; these tests verify the access control / read-back
///      shape of the rebase-bucket slot and the inherited NFT tracking.
contract HydrexPortfolioFactoryConfigTest is VeHydrexDiamond {
    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();
    }

    // ----------------------------------------------------------------
    // setRebaseTokenId access control
    // ----------------------------------------------------------------

    function test_setRebaseTokenId_revertsForArbitraryCaller() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(NFTPortfolioFactoryConfig.NotPortfolio.selector, address(0xBEEF)));
        portfolioFactoryConfig.setRebaseTokenId(42);
    }

    function test_setRebaseTokenId_callableByPortfolioAccount() public {
        // Routes via a permanent-incoming-token through the receiver hook
        // which is the only on-chain caller of setRebaseTokenId. Confirms
        // a registered portfolio passes the onlyPortfolio_ gate.
        uint256 tokenId = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);

        assertEq(
            portfolioFactoryConfig.getRebaseTokenId(portfolioAccount),
            tokenId,
            "portfolio set the bucket"
        );
    }

    function test_setRebaseTokenId_clearsToZero() public {
        // Path: arrive permanent -> set bucket. Then transfer out, then a fresh
        // permanent arrives -> bucket re-points to the fresh token (stale guard).
        uint256 first = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);
        ve.setOwner(first, address(0xDEAD));

        uint256 fresh = ve.mintTo(address(this), 1e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, fresh);

        assertEq(portfolioFactoryConfig.getRebaseTokenId(portfolioAccount), fresh, "re-bucketed");
    }

    function test_getRebaseTokenId_defaultsToZero() public view {
        assertEq(portfolioFactoryConfig.getRebaseTokenId(address(0xABCD)), 0, "unset default");
    }

    // ----------------------------------------------------------------
    // Inherits NFT tracking (NFTPortfolioFactoryConfig)
    // ----------------------------------------------------------------

    function test_inheritsNFTTracking_addsTokenToPortfolioAndFactorySets() public {
        underlying.mint(user, 5e18);
        vm.startPrank(user);
        underlying.approve(portfolioAccount, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(portfolioAccount);
        underlying.approve(address(ve), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(
                VeHydrexVotingEscrowFacet.createLock.selector,
                uint256(5e18),
                IHydrexVotingEscrow.LockType.ROLLING
            )
        );
        bytes[] memory results = portfolioManager.multicall(cd, fac);
        uint256 tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();

        assertTrue(
            portfolioFactoryConfig.hasToken(portfolioAccount, address(ve), tokenId),
            "tracked per-portfolio"
        );
        assertTrue(portfolioFactoryConfig.factoryHasToken(address(ve), tokenId), "tracked per-factory");
    }

    function test_getTokenCountByPortfolio_reflectsAdds() public {
        underlying.mint(user, 10e18);
        vm.startPrank(user);
        underlying.approve(portfolioAccount, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(portfolioAccount);
        underlying.approve(address(ve), type(uint256).max);
        vm.stopPrank();

        uint256 before_ = portfolioFactoryConfig.getTokenCountByPortfolio(portfolioAccount, address(ve));

        vm.startPrank(user);
        (bytes[] memory cd1, address[] memory fac1) = _mc(
            abi.encodeWithSelector(
                VeHydrexVotingEscrowFacet.createLock.selector,
                uint256(2e18),
                IHydrexVotingEscrow.LockType.ROLLING
            )
        );
        portfolioManager.multicall(cd1, fac1);
        (bytes[] memory cd2, address[] memory fac2) = _mc(
            abi.encodeWithSelector(
                VeHydrexVotingEscrowFacet.createLock.selector,
                uint256(3e18),
                IHydrexVotingEscrow.LockType.ROLLING
            )
        );
        portfolioManager.multicall(cd2, fac2);
        vm.stopPrank();

        assertEq(
            portfolioFactoryConfig.getTokenCountByPortfolio(portfolioAccount, address(ve)),
            before_ + 2,
            "two tokens tracked"
        );
    }
}
