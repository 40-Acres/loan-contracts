// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/facets/collateral/CollateralFacet.sol";
import "../src/interfaces/ICollateralFacet.sol";
import "../src/accounts/PortfolioFactory.sol";
import "../src/accounts/FacetRegistry.sol";
import "../src/diamonds/DiamondHitch.sol";
import "../src/facets/core/DiamondCutFacet.sol";
import "../src/facets/core/DiamondLoupeFacet.sol";
import "../src/facets/core/OwnershipFacet.sol";
import "../src/interfaces/IDiamondCut.sol";

/**
 * @title CollateralFacetTest
 * @dev Test suite for CollateralFacet in diamond pattern
 */
contract CollateralFacetTest is Test {
    
    address internal diamond;
    DiamondCutFacet internal diamondCutFacet;
    DiamondLoupeFacet internal diamondLoupeFacet;
    OwnershipFacet internal ownershipFacet;
    CollateralFacet internal collateralFacet;
    PortfolioFactory internal portfolioFactory;
    
    address internal testAccount = address(0x1234);
    address internal tokenAddress = address(0x5678);
    uint256 internal assetId = 1;
    uint256 internal amount = 1000;
    
    function setUp() public {
        // Deploy core facets
        diamondCutFacet = new DiamondCutFacet();
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        collateralFacet = new CollateralFacet();
        
        // Deploy portfolio factory
        FacetRegistry facetRegistry = new FacetRegistry();
        portfolioFactory = new PortfolioFactory(address(facetRegistry));
        
        // Deploy diamond
        diamond = address(new DiamondHitch(address(this), address(diamondCutFacet)));
        
        // Add facets to diamond
        _addFacetsToDiamond();
        
        // Initialize collateral storage
        ICollateralFacet(diamond).initCollateralStorage(address(portfolioFactory));
    }
    
    function _addFacetsToDiamond() internal {
        // Prepare function selectors for each facet
        bytes4[] memory collateralSelectors = new bytes4[](10);
        collateralSelectors[0] = ICollateralFacet.addNonfungibleCollateral.selector;
        collateralSelectors[1] = ICollateralFacet.addFungibleCollateral.selector;
        collateralSelectors[2] = ICollateralFacet.addTotalCollateral.selector;
        collateralSelectors[3] = ICollateralFacet.removeNonfungibleCollateral.selector;
        collateralSelectors[4] = ICollateralFacet.removeFungibleCollateral.selector;
        collateralSelectors[5] = ICollateralFacet.removeTotalCollateral.selector;
        collateralSelectors[6] = ICollateralFacet.getNonfungibleCollateral.selector;
        collateralSelectors[7] = ICollateralFacet.getFungibleCollateral.selector;
        collateralSelectors[8] = ICollateralFacet.getTotalCollateral.selector;
        collateralSelectors[9] = ICollateralFacet.initCollateralStorage.selector;
        
        // Create facet cuts
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(collateralFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: collateralSelectors
        });
        
        // Execute diamond cut
        IDiamondCut(diamond).diamondCut(cuts, address(0), new bytes(0));
    }
    
    function testAddNonfungibleCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Add nonfungible collateral
        vm.prank(testAccount);
        ICollateralFacet(diamond).addNonfungibleCollateral(tokenAddress, assetId);
        
        // Verify the collateral was added
        bool isCollateral = ICollateralFacet(diamond).getNonfungibleCollateral(testAccount, tokenAddress, assetId);
        assertTrue(isCollateral);
    }
    
    function testAddFungibleCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Add fungible collateral
        vm.prank(testAccount);
        ICollateralFacet(diamond).addFungibleCollateral(tokenAddress, amount);
        
        // Verify the collateral was added
        uint256 collateralAmount = ICollateralFacet(diamond).getFungibleCollateral(testAccount, tokenAddress);
        assertEq(collateralAmount, amount);
    }
    
    function testAddTotalCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Add total collateral
        vm.prank(testAccount);
        ICollateralFacet(diamond).addTotalCollateral(tokenAddress);
        
        // Verify the collateral was added
        bool isTotalCollateral = ICollateralFacet(diamond).getTotalCollateral(testAccount, tokenAddress);
        assertTrue(isTotalCollateral);
    }
    
    function testRemoveNonfungibleCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Add nonfungible collateral first
        vm.prank(testAccount);
        ICollateralFacet(diamond).addNonfungibleCollateral(tokenAddress, assetId);
        
        // Remove nonfungible collateral
        vm.prank(testAccount);
        ICollateralFacet(diamond).removeNonfungibleCollateral(tokenAddress, assetId);
        
        // Verify the collateral was removed
        bool isCollateral = ICollateralFacet(diamond).getNonfungibleCollateral(testAccount, tokenAddress, assetId);
        assertFalse(isCollateral);
    }
    
    function testRemoveFungibleCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Add fungible collateral first
        vm.prank(testAccount);
        ICollateralFacet(diamond).addFungibleCollateral(tokenAddress, amount);
        
        // Remove fungible collateral
        vm.prank(testAccount);
        ICollateralFacet(diamond).removeFungibleCollateral(tokenAddress, amount);
        
        // Verify the collateral was removed
        uint256 collateralAmount = ICollateralFacet(diamond).getFungibleCollateral(testAccount, tokenAddress);
        assertEq(collateralAmount, 0);
    }
    
    function testRemoveTotalCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Add total collateral first
        vm.prank(testAccount);
        ICollateralFacet(diamond).addTotalCollateral(tokenAddress);
        
        // Remove total collateral
        vm.prank(testAccount);
        ICollateralFacet(diamond).removeTotalCollateral(tokenAddress);
        
        // Verify the collateral was removed
        bool isTotalCollateral = ICollateralFacet(diamond).getTotalCollateral(testAccount, tokenAddress);
        assertFalse(isTotalCollateral);
    }
    
    function testOnlyPortfolioAccountCanAddCollateral() public {
        // Mock the portfolio factory to return false for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(0))
        );
        
        // Try to add collateral from non-portfolio account
        vm.prank(testAccount);
        vm.expectRevert("LibCollateral: Not a portfolio account");
        ICollateralFacet(diamond).addNonfungibleCollateral(tokenAddress, assetId);
    }
    
    function testCannotAddDuplicateNonfungibleCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Add nonfungible collateral
        vm.prank(testAccount);
        ICollateralFacet(diamond).addNonfungibleCollateral(tokenAddress, assetId);
        
        // Try to add the same collateral again
        vm.prank(testAccount);
        vm.expectRevert("LibCollateral: Asset already collateral");
        ICollateralFacet(diamond).addNonfungibleCollateral(tokenAddress, assetId);
    }
    
    function testCannotRemoveNonExistentCollateral() public {
        // Mock the portfolio factory to return true for ownerOf
        vm.mockCall(
            address(portfolioFactory),
            abi.encodeWithSelector(PortfolioFactory.ownerOf.selector, testAccount),
            abi.encode(address(1))
        );
        
        // Try to remove non-existent collateral
        vm.prank(testAccount);
        vm.expectRevert("LibCollateral: Asset not collateral");
        ICollateralFacet(diamond).removeNonfungibleCollateral(tokenAddress, assetId);
    }
}
