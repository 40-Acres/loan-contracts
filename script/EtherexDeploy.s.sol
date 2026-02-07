// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {EtherexLoan as Loan} from "src/Etherex/EtherexLoan.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/Vault.sol";
import {Vault as VaultV2} from "src/VaultV2.sol";
// import { EtherexSwapper as Swapper } from "../src/Etherex/EtherexSwapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Swapper} from "../src/Swapper.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {XRexFacet} from "../src/facets/account/XRexFacet.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {IXLoan} from "../src/interfaces/IXLoan.sol";
contract EtherexDeploy is Script {
    Swapper public swapper;
    address[] public supportedTokens;
    uint256 fork;
    address _rex = 0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4;
    address _asset = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
    address _deployer = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        deploy();
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
        AccountConfigStorage accountConfigStorage = AccountConfigStorage(
            address(accountConfigStorageProxy)
        );
        accountConfigStorage.initialize();
        Loan loanImplementation = new Loan();
        ERC1967Proxy _loan = new ERC1967Proxy(address(loanImplementation), "");
        VaultV2 vaultImplementation = new VaultV2();
        ERC1967Proxy _vault = new ERC1967Proxy(
            address(vaultImplementation),
            ""
        );

        Vault vault = Vault(payable(_vault));
        VaultV2(address(vault)).initialize(
            address(_asset),
            address(_loan),
            "40ETHEREX-USDC-VAULT",
            "40ETHEREX-USDC-VAULT"
        );

        Loan loan = Loan(payable(_loan));
        Loan(address(loan)).initialize(address(_vault), _asset);
        loan.setProtocolFee(500);
        loan.setLenderPremium(2000);
        loan.setZeroBalanceFee(100);

        // Set default pools and weights after upgrade
        address[] memory defaultPools = new address[](1);
        defaultPools[0] = 0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e; // Use the working pool address
        uint256[] memory defaultWeights = new uint256[](1);
        defaultWeights[0] = 100e18;

        // Approve the default pool
        loan.setApprovedPools(defaultPools, true);
        // Set the default pools and weights
        loan.setDefaultPools(defaultPools, defaultWeights);

        address[] memory _supportedTokens = new address[](2);
        _supportedTokens[0] = _rex;
        _supportedTokens[1] = _asset;
        supportedTokens = _supportedTokens;

        FacetRegistry facetRegistry = new FacetRegistry(_deployer);

        // Deploy PortfolioFactory

        PortfolioFactory portfolioFactory = new PortfolioFactory(
            address(facetRegistry)
        );

        console.log("UniversalPortfolioFactory:", address(portfolioFactory));

        // Deploy swapper with Avalanche factory and router addresses
        swapper = new Swapper(
            address(0x85974429677c2a701af470B82F3118e74307826e), // factory
            address(0xAe334f70A7FC44FCC2df9e6A37BC032497Cf80f1), // router
            supportedTokens
        );
        loan.setSwapper(address(swapper));

        loan.setPortfolioFactory(address(portfolioFactory));
        loan.transferOwnership(
            address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0)
        );

        accountConfigStorage.setApprovedContract(address(loan), true);
        XRexFacet loanFacet = new XRexFacet(
            address(portfolioFactory),
            address(accountConfigStorage)
        );

        // Register XRexFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](8);
        loanSelectors[0] = 0x6d3daeb9; // xRexRequestLoan(uint256,address,uint256,uint8,uint256,address,bool)
        loanSelectors[1] = 0x86e057a2; // xRexIncreaseLoan(address,uint256)
        loanSelectors[2] = 0x60be0290; // xRexIncreaseCollateral(address,uint256)
        loanSelectors[3] = 0xd56b124c; // xRexClaimCollateral(address,uint256)
        loanSelectors[4] = 0x410f6461; // xRexVote(address)
        loanSelectors[5] = 0x89512b6a; // xRexUserVote(address,address[],uint256[])
        loanSelectors[6] = 0x5f98cbbf; // xRexClaim(address,address[],address[][],bytes,uint256[2])
        loanSelectors[7] = 0xa1d8cd01; // xRexProcessRewards(address[],address[][],bytes)

        // Get the FacetRegistry from the PortfolioFactory
        facetRegistry = FacetRegistry(portfolioFactory.facetRegistry());
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "XRexFacet"
        );
        return (loan, vault, swapper, accountConfigStorage, portfolioFactory);
    }
}


contract EtherexUpgrade is Script {
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
        XRexFacet xRexFacet = new XRexFacet(address(_portfolioFactory), address(_accountConfigStorage));
        FacetRegistry facetRegistry = FacetRegistry(address(_facetRegistry));
        Loan loanImplementation = new Loan();

        vm.startPrank(0x97BE22DBb49C88451fBd1099F59EED963d9d8A12);
        _loan.upgradeToAndCall(address(loanImplementation), new bytes(0));

        // All selectors for the new XRexFacet (including the new xRexProcessRewards function)
        bytes4[] memory newSelectors = new bytes4[](8);
        newSelectors[0] = 0x6d3daeb9; // xRexRequestLoan(uint256,address,uint256,uint8,uint256,address,bool)
        newSelectors[1] = 0x86e057a2; // xRexIncreaseLoan(address,uint256)
        newSelectors[2] = 0x60be0290; // xRexIncreaseCollateral(address,uint256)
        newSelectors[3] = 0xd56b124c; // xRexClaimCollateral(address,uint256)
        newSelectors[4] = 0x410f6461; // xRexVote(address)
        newSelectors[5] = 0x89512b6a; // xRexUserVote(address,address[],uint256[])
        newSelectors[6] = 0x5f98cbbf; // xRexClaim(address,address[],address[][],bytes,uint256[2])
        newSelectors[7] = 0xa1d8cd01; // xRexProcessRewards(address[],address[][],bytes)

        // Replace the old facet with the new one (this handles removal and registration in one call)
        _facetRegistry.replaceFacet(
            0x7aF55307660d3e42088a8cAE0e36Fe6d001d00aa, // old facet address
            address(xRexFacet), // new facet address
            newSelectors,
            "XRexFacet"
        );

    }

}

// forge script script/EtherexDeploy.s.sol:EtherexDeploy  --chain-id 59144 --rpc-url $LINEA_RPC_URL --etherscan-api-key $LINEASCAN_API_KEY --broadcast --verify --via-ir --evm-version london
// forge script script/EtherexDeploy.s.sol:EtherexDepositNft  --chain-id 59144 --rpc-url $LINEA_RPC_URL --etherscan-api-key $LINEASCAN_API_KEY --broadcast --verify --via-ir --evm-version london
// forge script script/EtherexDeploy.s.sol:EtherexUpgrade  --chain-id 59144 --rpc-url $LINEA_RPC_URL --etherscan-api-key $LINEASCAN_API_KEY --broadcast --verify --via-ir --evm-version london
