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
import {PharaohLoanV2} from "../src/Pharaoh/PharaohLoanV2.sol";
import {Vault as PharaohVault} from "../src/Pharaoh/PharaohVault.sol";
interface IOwnable {
    function owner() external view returns (address);
}


contract XPharaohDeploy is Script {
    Swapper public swapper;
    address[] public supportedTokens;
    uint256 fork;
    address _rex = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    address _asset = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address _owner = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        console.log("Deploying XPharaohLoan from address:", msg.sender);
        new PharaohLoanV2();
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
        
        PharaohVault vaultImplementation = new PharaohVault();
        ERC1967Proxy _vault = new ERC1967Proxy(address(vaultImplementation), "");
        PharaohVault vault = PharaohVault(payable(_vault));
        vault.initialize(address(_asset), address(_loan), "40xpharaoh-USDC-VAULT", "40xpharaoh-USDC-VAULT");

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
        address owner = IOwnable(address(facetRegistry)).owner();
        console.log("FacetRegistry owner:", owner);
        vm.stopPrank();
        vm.startPrank(owner);
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "XPharaohFacet"
        );
        facetRegistry.transferOwnership(address(_owner));
        vm.stopPrank();
        vm.startPrank(0x40FecA5f7156030b78200450852792ea93f7c6cd);
        loan.setPortfolioFactory(address(portfolioFactory));

        loan.transferOwnership(
            address(_owner)
        );
        accountConfigStorage.transferOwnership(address(_owner));
    
        accountConfigStorage.setApprovedContract(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F, true);

        return (loan, Vault(address(vault)), swapper, accountConfigStorage, portfolioFactory);
    }
}

contract XPharaohUpgrade is Script {
    address[] public supportedTokens;
    uint256 fork;
    AccountConfigStorage _accountConfigStorage = AccountConfigStorage(0x17cd3c65daf5b2F806d053D948Ad7d59191fd397);
    FacetRegistry _facetRegistry = FacetRegistry(0x9bCa68D9c613Dc9B07B2727c28b5ce46204943de);
    PortfolioFactory _portfolioFactory = PortfolioFactory(0x52d43C377e498980135C8F2E858f120A18Ea96C2);
    Loan _loan = Loan(0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C);

    function run() external  {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgrade();
    }

    function mock() public {
        vm.startPrank(0x40FecA5f7156030b78200450852792ea93f7c6cd);
        upgrade();
        vm.stopPrank();
    }

    function upgrade() public {
        XPharaohFacet xPharaohFacet = new XPharaohFacet(address(_portfolioFactory), address(_accountConfigStorage));
// 
        // new XPharaohFacet();


        // // PharaohVault vaultImpl = new PharaohVault();
        // console.log("PharaohVault:", address(vaultImpl));
        // vm.startPrank(IOwnable(address(_loan)).owner());
        // FacetRegistry facetRegistry = FacetRegistry(address(_facetRegistry));

        // // All selectors for the new XPharoFacet" (including the new xRexProcessRewards function)
        // bytes4[] memory newSelectors = new bytes4[](9);
        // newSelectors[0] = 0xdbbe2f11; // xPharRequestLoan(uint256,address,uint256,uint8,uint256,address,bool)
        // newSelectors[1] = 0x6514a9ff; // xPharIncreaseLoan(address,uint256)
        // newSelectors[2] = 0x100228bb; // xPharIncreaseCollateral(address,uint256)
        // newSelectors[3] = 0x7d9b5dc7; // xPharClaimCollateral(address,uint256)
        // newSelectors[4] = 0x31f84426; // xPharVote(address)
        // newSelectors[5] = 0xafe53449; // xPharUserVote(address,address[],uint256[])
        // newSelectors[6] = 0x574b41f0; // xPharClaim(address,address[],address[][],bytes,uint256[2])
        // newSelectors[7] = 0x73aa54b2; // xPharProcessRewards(address[],address[][],bytes)
        // newSelectors[8] = 0x61622de4; // migratePharaohToXPharaoh(uint256)

        // // Replace the old facet with the new one (this handles removal and registration in one call)
        // _facetRegistry.replaceFacet(
        //     0x150c52c1E8707C2E4372974e352BBf20baFAF08D, // old facet address
        //     address(xPharaohFacet), // new facet address
        //     newSelectors,
        //     "XPharaohFacet"
        // );

    }


}

// forge script script/XPharaohDeploy.s.sol:XPharaohDeploy  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/XPharaohDeploy.s.sol:XPharaohDepositNft  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/XPharaohDeploy.s.sol:XPharaohUpgrade  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir