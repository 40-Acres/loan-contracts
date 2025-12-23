// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {Setup} from "../utils/Setup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {IVexyMarketplace} from "../../../src/interfaces/external/IVexyMarketplace.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {SwapFacet} from "../../../src/facets/account/swap/SwapFacet.sol";

contract VexyMarketplaceTest is Test, Setup {
    uint256 constant VEXY_LISTING_ID = 3933;
    address constant VEXY = 0x6b478209974BD27e6cf661FEf86C68072b0d6738;
    MockOdosRouterRL public mockRouter;

    // Helper function to add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testBuyVexyListingNoLoan() public {
        // assert the getLockedCollateral returns the correct collateral
        (uint256 prevMaxLoan, uint256 prevMaxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(prevMaxLoan, 0);
        assertEq(prevMaxLoanIgnoreSupply, 0);

        // ensure vexy listing is still available, and get the price/currency
        (
            ,
            ,
            address nftCollection,
            uint256 nftId,
            address currency,
            ,
            uint256 price,
            ,
            ,
            uint64 endTime,
            uint64 soldTime
        ) = IVexyMarketplace(VEXY).listings(VEXY_LISTING_ID);

        assertEq(soldTime, 0, "Listing should not be sold");

        deal(currency, _user, price);

        vm.startPrank(_user);
        IERC20(currency).approve(_portfolioAccount, price);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VexyFacet.buyVexyListing.selector,
            VEXY_LISTING_ID,
            _user
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // assert the getLockedCollateral returns the correct collateral
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertTrue(maxLoanIgnoreSupply > prevMaxLoanIgnoreSupply);
    }

    function testBuyVexyListingWithSwap() public {
        // assert the getLockedCollateral returns the correct collateral
        (uint256 prevMaxLoan, uint256 prevMaxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(prevMaxLoan, 0);
        assertEq(prevMaxLoanIgnoreSupply, 0);

        // ensure vexy listing is still available, and get the price/currency
        (
            ,
            ,
            address nftCollection,
            uint256 nftId,
            address currency,
            ,
            uint256 price,
            ,
            ,
            uint64 endTime,
            uint64 soldTime
        ) = IVexyMarketplace(VEXY).listings(VEXY_LISTING_ID);

        assertEq(soldTime, 0, "Listing should not be sold");

        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));
        
        // Approve the mock router as a swap target (requires owner)
        vm.startPrank(_owner);
        _swapConfig.approveSwapTarget(address(mockRouter));
        vm.stopPrank();

        // Fund user with USDC (input token for swap) and currency (for buyVexyListing approval)
        deal(address(_usdc), _user, price);
        deal(currency, _user, price);

        vm.startPrank(_user);
        // Approve portfolio account to pull tokens (userSwap will transferFrom USDC, buyVexyListing will transferFrom currency)
        IERC20(address(_usdc)).approve(_portfolioAccount, price);
        IERC20(currency).approve(_portfolioAccount, price);
        address[] memory portfolioFactories = new address[](2);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](2);

        // Create swap data to call executeSwap on MockOdosRouter
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            _usdc,            // inputToken
            currency,             // outputToken (same for now, but could be different)
            price,               // inputAmount
            price,               // amountOut
            _portfolioAccount    // receiver
        );

        calldatas[0] = abi.encodeWithSelector(
            SwapFacet.userSwap.selector,
            address(_swapConfig), // swapConfig
            address(mockRouter),  // swapTarget
            swapData,            // swapData
            _usdc,            // inputToken
            price,                // inputAmount
            currency,             // outputToken
            price                 // minimumOutputAmount
        );
        calldatas[1] = abi.encodeWithSelector(
            VexyFacet.buyVexyListing.selector,
            VEXY_LISTING_ID,
            _user
        );

        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();


        // assert the getLockedCollateral returns the correct collateral
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertTrue(maxLoanIgnoreSupply > prevMaxLoanIgnoreSupply);
    }

}
