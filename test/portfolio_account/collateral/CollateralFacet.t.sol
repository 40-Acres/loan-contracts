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

    // Origination fee is 0.8% (80/10000)
    function _withFee(uint256 amount) internal pure returns (uint256) {
        return amount + (amount * 80) / 10000;
    }

    // Helper function to add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to remove collateral via PortfolioManager multicall
    function removeCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.removeCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to pay via PortfolioManager multicall
    function payViaMulticall(uint256 tokenId, uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.pay.selector,
            tokenId,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    function testAddCollateralWithinPortfolioAccount() public {
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        addCollateralViaMulticall(_tokenId);
        int128 lockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(lockedAmount)));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function testAddCollateralOutsidePortfolioAccount() public {
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        // Transfer token to portfolio owner first
        vm.startPrank(_portfolioAccount);
        IVotingEscrow(_ve).transferFrom(_portfolioAccount, _user, _tokenId);
        vm.stopPrank();
        // Approve portfolio account to transfer the token
        vm.startPrank(_user);
        IVotingEscrow(_ve).approve(_portfolioAccount, _tokenId);
        vm.stopPrank();
        addCollateralViaMulticall(_tokenId);

        int128 lockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(lockedAmount)));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function testAddingCollateralTwice() public {
        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(_tokenId);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(IVotingEscrow(_ve).locked(_tokenId).amount)));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
    }

    function testRemovingCollateral() public {
        addCollateralViaMulticall(_tokenId);
        removeCollateralViaMulticall(_tokenId);
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioFactory.ownerOf(_portfolioAccount));
    }

    function testRemoveCollateralWithDebt() public {
        // should revert since no collateral is added
        vm.expectRevert();
        borrowViaMulticall(1e6);
        
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 1e6;
        borrowViaMulticall(borrowAmount);
        
        // should revert since collateral is not enough (has debt)
        vm.expectRevert();
        removeCollateralViaMulticall(_tokenId);

        // Pay back full debt (includes 0.8% origination fee)
        uint256 fullDebt = _withFee(borrowAmount);
        
        // Fund portfolio with extra USDC for fee payment
        uint256 currentBalance = _asset.balanceOf(_portfolioAccount);
        deal(address(_asset), _portfolioAccount, currentBalance + fullDebt);
        
        payViaMulticall(_tokenId, fullDebt);
        removeCollateralViaMulticall(_tokenId);
        
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioFactory.ownerOf(_portfolioAccount));
    }

    function testRemoveCollateralWithMultipleTokens() public {
        uint256 _tokenId2 = 84298;

        vm.startPrank(IVotingEscrow(_ve).ownerOf(_tokenId2));
        IVotingEscrow(_ve).transferFrom(IVotingEscrow(_ve).ownerOf(_tokenId2), _portfolioAccount, _tokenId2);
        vm.stopPrank();

        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(_tokenId2);
        uint256 borrowAmount = 1e6;
        borrowViaMulticall(borrowAmount);
        removeCollateralViaMulticall(_tokenId2);
        
        int128 lockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), uint256(uint128(lockedAmount)));
        // Debt includes 0.8% origination fee
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), _withFee(borrowAmount));
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId2), _portfolioFactory.ownerOf(_portfolioAccount));
    }
}