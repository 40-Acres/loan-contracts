pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {PortfolioFactoryDeploy} from "../../../script/portfolio_account/PortfolioFactoryDeploy.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {Setup} from "../utils/Setup.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";

contract CollateralFacetTest is Test, Setup {

    function testAddCollateralWithinPortfolioAccount() public {
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        int128 lockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(lockedAmount)));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function testAddCollateralOutsidePortfolioAccount() public {
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        vm.startPrank(address(0x40ac2f));
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        vm.stopPrank();

        int128 lockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(lockedAmount)));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function testAddingCollateralTwice() public {
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(IVotingEscrow(_ve).locked(_tokenId).amount)));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function testRemovingCollateral() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        CollateralFacet(_portfolioAccount).removeCollateral(_tokenId);
        vm.stopPrank();
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioFactory.ownerOf(_portfolioAccount));
    }

    function testRemoveCollateralWithDebt() public {
        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        // should revert since no collateral is added
        vm.expectRevert();
        LendingFacet(_portfolioAccount).borrow(1e6);
        
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        LendingFacet(_portfolioAccount).borrow(1e6);
        // should revert since collateral is not enough
        vm.expectRevert();
        CollateralFacet(_portfolioAccount).removeCollateral(_tokenId);

        LendingFacet(_portfolioAccount).pay(1e6);
        CollateralFacet(_portfolioAccount).removeCollateral(_tokenId);
        vm.stopPrank();
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioFactory.ownerOf(_portfolioAccount));
    }

    function testRemoveCollateralWithMultipleTokens() public {
        uint256 _tokenId2 = 84298;

        vm.startPrank(IVotingEscrow(_ve).ownerOf(_tokenId2));
        IVotingEscrow(_ve).transferFrom(IVotingEscrow(_ve).ownerOf(_tokenId2), _portfolioAccount, _tokenId2);
        vm.stopPrank();

        vm.startPrank(_portfolioFactory.ownerOf(_portfolioAccount));
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId);
        CollateralFacet(_portfolioAccount).addCollateral(_tokenId2);
        LendingFacet(_portfolioAccount).borrow(1e6);
        CollateralFacet(_portfolioAccount).removeCollateral(_tokenId2);
        vm.stopPrank();
        int128 lockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(lockedAmount)));
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 1e6);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId2), _portfolioFactory.ownerOf(_portfolioAccount));
    }
}