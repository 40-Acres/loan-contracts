// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/facets/collateral/CollateralFacet.sol";
import "../src/interfaces/ICollateralFacet.sol";
import "../src/interfaces/IDiamondCut.sol";

/**
 * @title CollateralFacetDeploy
 * @dev Deployment script for CollateralFacet in diamond pattern
 */
contract CollateralFacetDeploy is Script {
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address diamondAddress = vm.envAddress("DIAMOND_ADDRESS");
        address portfolioFactory = vm.envAddress("PORTFOLIO_FACTORY_ADDRESS");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy CollateralFacet
        CollateralFacet collateralFacet = new CollateralFacet();
        console.log("CollateralFacet deployed at:", address(collateralFacet));
        
        // Prepare function selectors for CollateralFacet
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
        
        // Create facet cut for adding CollateralFacet
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(collateralFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: collateralSelectors
        });
        
        // Initialize collateral storage
        bytes memory initCalldata = abi.encodeWithSelector(
            ICollateralFacet.initCollateralStorage.selector,
            portfolioFactory
        );
        
        // Execute diamond cut
        IDiamondCut(diamondAddress).diamondCut(cuts, address(collateralFacet), initCalldata);
        console.log("CollateralFacet added to diamond at:", diamondAddress);
        
        vm.stopBroadcast();
    }
}
