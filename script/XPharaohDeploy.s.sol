// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {XPharaohLoan as Loan} from "src/Pharaoh/XPharaohLoan.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/Vault.sol";
import {Vault as VaultV2} from "src/VaultV2.sol";
// import { XPharaohSwapper as Swapper } from "../src/XPharaoh/XPharaohSwapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Swapper} from "../src/Swapper.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {XPharaohFacet} from "../src/facets/account/XPharaohFacet.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {IXLoan} from "../src/interfaces/IXLoan.sol";

contract XPharaohDeploy is Script {
    Swapper public swapper;
    address[] public supportedTokens;
    uint256 fork;
    address _rex = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    address _asset = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address _owner = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    Vault vault = Vault(0x124D00b1ce4453Ffc5a5F65cE83aF13A7709baC7);

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        console.log("Deploying XPharaohLoan from address:", msg.sender);
        deploy();
        vm.stopBroadcast();
    }

    function mock() public
        returns (Loan, Vault, Swapper, AccountConfigStorage, PortfolioFactory) {
        vm.startPrank(0x40FecA5f7156030b78200450852792ea93f7c6cd);
        (Loan loan, Vault vault, Swapper swapper, AccountConfigStorage accountConfigStorage, PortfolioFactory portfolioFactory) = deploy();
        vm.stopPrank();
        return (loan, vault, swapper, accountConfigStorage, portfolioFactory);
    }

    function deploy()
        public
        returns (Loan, Vault, Swapper, AccountConfigStorage, PortfolioFactory)
    {
        AccountConfigStorage _accountConfigStorage = new AccountConfigStorage();
        ERC1967Proxy accountConfigStorageProxy = new ERC1967Proxy(
            address(_accountConfigStorage),
            ""
        );
        console.log("Deploying AccountConfigStorage address:", address(accountConfigStorageProxy));
        AccountConfigStorage accountConfigStorage = AccountConfigStorage(
            address(accountConfigStorageProxy)
        );
        accountConfigStorage.initialize();
        Loan loanImplementation = new Loan();
        ERC1967Proxy _loan = new ERC1967Proxy(address(loanImplementation), "");
        console.log("Deploying Loan address:", address(_loan));

        Loan loan = Loan(payable(_loan));
        Loan(address(loan)).initialize(address(vault), _asset);
        loan.setProtocolFee(500);
        loan.setLenderPremium(2000);
        loan.setZeroBalanceFee(100);

        // // Set default pools and weights after upgrade
        // address[] memory defaultPools = new address[](1);
        // defaultPools[0] = 0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e; // Use the working pool address
        // uint256[] memory defaultWeights = new uint256[](1);
        // defaultWeights[0] = 100e18;

        // // Approve the default pool
        // loan.setApprovedPools(defaultPools, true);
        // // Set the default pools and weights
        // loan.setDefaultPools(defaultPools, defaultWeights);

        address[] memory _supportedTokens = new address[](2);
        _supportedTokens[0] = _rex;
        _supportedTokens[1] = _asset;
        supportedTokens = _supportedTokens;
        FacetRegistry facetRegistry = new FacetRegistry();

        // Deploy PortfolioFactory

        PortfolioFactory portfolioFactory = new PortfolioFactory(
            address(facetRegistry)
        );


        console.log("FacetRegistry:", address(facetRegistry));
        console.log("PortfolioFactory:", address(portfolioFactory));
        // Deploy swapper with Avalanche factory and router addresses
        swapper = new Swapper(
            address(0x85974429677c2a701af470B82F3118e74307826e), // factory
            address(0xAe334f70A7FC44FCC2df9e6A37BC032497Cf80f1), // router
            supportedTokens
        );
        loan.setSwapper(address(swapper));

        loan.setPortfolioFactory(address(portfolioFactory));
        accountConfigStorage.setApprovedContract(address(loan), true);
        XPharaohFacet loanFacet = new XPharaohFacet(
            address(portfolioFactory),
            address(accountConfigStorage)
        );

        // Register XPharaohFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](9);
        loanSelectors[0] = 0xdbbe2f11; // xPharRequestLoan(uint256,address,uint256,uint8,uint256,address,bool)
        loanSelectors[1] = 0x6514a9ff; // xPharIncreaseLoan(address,uint256)
        loanSelectors[2] = 0x100228bb; // xPharIncreaseCollateral(address,uint256)
        loanSelectors[3] = 0x7d9b5dc7; // xPharClaimCollateral(address,uint256)
        loanSelectors[4] = 0x31f84426; // xPharVote(address)
        loanSelectors[5] = 0xafe53449; // xPharUserVote(address,address[],uint256[])
        loanSelectors[6] = 0x574b41f0; // xPharClaim(address,address[],address[][],bytes,uint256[2])
        loanSelectors[7] = 0x73aa54b2; // xPharProcessRewards(address[],address[][],bytes)
        loanSelectors[8] = 0x61622de4; // migratePharaohToXPharaoh(uint256)

        // Get the FacetRegistry from the PortfolioFactory
        facetRegistry = FacetRegistry(portfolioFactory.facetRegistry());
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "XPharaohFacet"
        );
        loan.setPortfolioFactory(address(portfolioFactory));

        loan.transferOwnership(
            address(_owner)
        );
        accountConfigStorage.transferOwnership(address(_owner));
        facetRegistry.transferOwnership(address(_owner));
    
        accountConfigStorage.setApprovedContract(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F, true);

        return (loan, vault, swapper, accountConfigStorage, portfolioFactory);
    }
}


contract XPharaohUpgrade is Script {
    address[] public supportedTokens;
    uint256 fork;
    AccountConfigStorage _accountConfigStorage = AccountConfigStorage(0x65EC3E4E01bD6DF8806106374c0Aa40FF2C5a6c3);
    FacetRegistry _facetRegistry = FacetRegistry(0x1A37F063D6423f4158AB8cD2D172378678F87093);
    PortfolioFactory _portfolioFactory = PortfolioFactory(0x2155F306d2806d745427A3E04721e8Cf6F8327dd);
    Loan _loan = Loan(0xCca5628DF6e5B16a1610d62467df34E07317A891);

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        upgrade();
    }

    function mock() public {
        vm.startPrank(0x40FecA5f7156030b78200450852792ea93f7c6cd);
        upgrade();
        vm.stopPrank();
    }

    function upgrade() public {
        // AccountConfigStorage accountConfigStorageImpl = new AccountConfigStorage();
        // AccountConfigStorage(address(_accountConfigStorage)).upgradeToAndCall(address(accountConfigStorageImpl), new bytes(0));
        // _accountConfigStorage.setAuthorizedCaller(address(0xf161e7c79e0c0A3FD8D75A05A53A04E05B2034d3), true);
        XPharaohFacet xPharaohFacet = new XPharaohFacet(address(_portfolioFactory), address(_accountConfigStorage));
        FacetRegistry facetRegistry = FacetRegistry(address(_facetRegistry));
        Loan loanImplementation = new Loan();

        vm.startPrank(0x97BE22DBb49C88451fBd1099F59EED963d9d8A12);
        _loan.upgradeToAndCall(address(loanImplementation), new bytes(0));

        // All selectors for the new XPharaohFacet (including the new xPharProcessRewards function)
        bytes4[] memory newSelectors = new bytes4[](8);
        newSelectors[0] = 0xdbbe2f11; // xPharRequestLoan(uint256,address,uint256,uint8,uint256,address,bool)
        newSelectors[1] = 0x6514a9ff; // xPharIncreaseLoan(address,uint256)
        newSelectors[2] = 0x100228bb; // xPharIncreaseCollateral(address,uint256)
        newSelectors[3] = 0x7d9b5dc7; // xPharClaimCollateral(address,uint256)
        newSelectors[4] = 0x31f84426; // xPharVote(address)
        newSelectors[5] = 0xafe53449; // xPharUserVote(address,address[],uint256[])
        newSelectors[6] = 0x574b41f0; // xPharClaim(address,address[],address[][],bytes,uint256[2])
        newSelectors[7] = 0x73aa54b2; // xPharProcessRewards(address[],address[][],bytes)

        // Replace the old facet with the new one (this handles removal and registration in one call)
        _facetRegistry.replaceFacet(
            0x7aF55307660d3e42088a8cAE0e36Fe6d001d00aa, // old facet address
            address(xPharaohFacet), // new facet address
            newSelectors,
            "XPharaohFacet"
        );

    }

}

// forge script script/XPharaohDeploy.s.sol:XPharaohDeploy  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/XPharaohDeploy.s.sol:XPharaohDepositNft  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/XPharaohDeploy.s.sol:XPharaohUpgrade  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
