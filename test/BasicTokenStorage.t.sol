// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/storage/AssetStorage.sol";
import "../src/accounts/PortfolioFactory.sol";
import "../src/accounts/FacetRegistry.sol";

/**
 * @title BasicAssetStorageTest
 * @dev Basic test for AssetStorage functionality
 */
contract BasicAssetStorageTest is Test {
    AssetStorage public assetStorage;
    PortfolioFactory public factory;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public mockToken = address(0x4);
    
    function setUp() public {
        // Deploy asset storage
        assetStorage = new AssetStorage();
        // Deploy FacetRegistry
        FacetRegistry facetRegistry = new FacetRegistry();
        
        // Deploy factory
        factory = new PortfolioFactory(
            address(assetStorage),
            address(facetRegistry)
        );

        // Authorize factory as caller for asset storage (owner is the test contract)
        assetStorage.authorizeCaller(address(factory));
        
        // Factory doesn't need authorization from account storage
        
        // Create account for user
        factory.createAccount(user1);
    }
    
    function testBasicNFTDeposit() public {
        // Test basic NFT deposit functionality
        address mockLoanContract = address(0x5);
        uint256 tokenId = 1;
        
        vm.prank(address(factory));
        assetStorage.depositAsset(user1, mockToken, tokenId, mockLoanContract);
        
        // Check asset exists
        assertTrue(assetStorage.assetExists(user1, mockToken, tokenId));
        assertEq(assetStorage.getAssetHandler(user1, mockToken, tokenId), mockLoanContract);
    }
    
    function testBasicNFTWithdraw() public {
        // First deposit
        address mockLoanContract = address(0x5);
        uint256 tokenId = 1;
        
        vm.prank(address(factory));
        assetStorage.depositAsset(user1, mockToken, tokenId, mockLoanContract);
        
        // Test withdraw
        vm.prank(address(factory));
        assetStorage.withdrawAsset(user1, mockToken, tokenId);
        
        // Check asset no longer exists
        assertFalse(assetStorage.assetExists(user1, mockToken, tokenId));
    }
    
    function testSetNFTCollateral() public {
        // First deposit
        address mockLoanContract = address(0x5);
        uint256 tokenId = 1;
        
        vm.prank(address(factory));
        assetStorage.depositAsset(user1, mockToken, tokenId, mockLoanContract);
        
        // Set as collateral
        vm.prank(address(factory));
        assetStorage.setAssetCollateral(user1, mockToken, tokenId, true);
        
        // Check collateral status
        assertTrue(assetStorage.isAssetCollateral(user1, mockToken, tokenId));
    }
    
    function testGetAccountNFTs() public {
        // First deposit
        address mockLoanContract = address(0x5);
        uint256 tokenId = 1;
        
        vm.prank(address(factory));
        assetStorage.depositAsset(user1, mockToken, tokenId, mockLoanContract);
        
        // Get account assets
        AssetStorage.NFTData[] memory assets = assetStorage.getAccountNFTs(user1);
        
        // Should have 1 asset
        assertEq(assets.length, 1);
        assertEq(assets[0].tokenAddress, mockToken);
        assertEq(assets[0].assetId, tokenId);
        assertEq(assets[0].assetHandler, mockLoanContract);
    }
}
