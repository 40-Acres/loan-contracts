// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {XPharaohLoan} from "../src/Pharaoh/XPharaohLoan.sol";
import {XPharaohFacet} from "../src/facets/account/XPharaohFacet.sol";
import {IXLoan} from "../src/interfaces/IXLoan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IXVoter} from "src/interfaces/IXVoter.sol";
import {Vault} from "src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/Pharaoh/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolTimeLibrary} from "src/libraries/ProtocolTimeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {XPharaohDeploy} from "../script/XPharaohDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {XPharaohUpgrade} from "../script/XPharaohDeploy.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";
import {IVoteModule} from "../src/interfaces/IVoteModule.sol";
import {IVoter} from "../src/interfaces/IVoter.sol";
import {PharaohLoan} from "../src/Pharaoh/PharaohLoan.sol";
import {PharaohLoanV2} from "../src/Pharaoh/PharaohLoanV2.sol";
import {ILoan} from "../src/interfaces/ILoan.sol";
import { Loan as Loanv2 } from "../src/LoanV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {XPharaohFacet} from "../src/facets/account/XPharaohFacet.sol";
import {Vault as PharaohVault} from "../src/Pharaoh/PharaohVault.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";


contract MockOdosRouterRL {
    address public testContract;

    address ODOS = 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC;
    address USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address PHAR = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address receiver) external returns (bool) {
        IERC20(tokenIn).transferFrom(receiver, address(this), amountIn);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(tokenOut).masterMinter(), receiver, amountOut));
        require(success, "mint fail");
        return true;
    }


    function executeSwapMultiOutput(uint256 amount1, uint256 amount2, address receiver) external returns (bool) {
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E).masterMinter(), receiver, amount1));
        require(success, "mint fail");

        (bool success2,) = testContract.call(abi.encodeWithSignature("mintRex(address,uint256)", receiver, amount2));
        require(success2, "mint rex fail");

        return true;
    }
}


interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(
        address minter,
        uint256 minterAllowedAmount
    ) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

contract XPharaohMigrationTest is Test {
    uint256 fork;
    uint256 fork2;
    uint256 _fork = vm.createFork(vm.envString("AVAX_RPC_URL"));

    IERC20 aero = IERC20(0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9);
    IUSDC usdc = IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IVotingEscrow votingEscrow =
        IVotingEscrow(0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);
    IERC20 weth = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IVoter public voter = IVoter(0xAAAf3D9CDD3602d117c67D80eEC37a160C8d9869);
    address[] pool = [address(0x1a2950978E29C5e590C77B0b6247beDbFB0b4185)];
    ProxyAdmin admin;

    // deployed contracts
    PharaohVault vault = PharaohVault(0x124D00b1ce4453Ffc5a5F65cE83aF13A7709baC7);
    PharaohLoanV2 public loan = PharaohLoanV2(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F);
    XPharaohFacet public loanFacet;
    XPharaohLoan public xloan = XPharaohLoan(0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C);
    address owner = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    address user;
    uint256 tokenId = 93;

    uint256 expectedRewards = 1269895;

    AccountConfigStorage accountConfigStorage;
    Swapper public swapper;
    address loanContract = 0xf6A044c3b2a3373eF2909E2474f3229f23279B5F;
    uint256[] tokens = [100,108,195,204,3111,3178,327,3383,3601,3618,3802,3818,3884,3954,3993,4141,420,4240,4345,4390,4496,4554,4593,4613,4995,4997,502,5186,5418,5447,5451,5510,5595,5603,5604,5618,5831,5959,5961,5962,6083,6088,6091,6093,6106,6107,6132,6135,6136,6163,6179,6301,6304,6337,6341,6346,6351,6378,6391,6396,6397,6419,6427,6430,6452,6457,6459,6511,6513,6515,6517,6521,6524,6530,6552,6554,6613,6617,6699,6734,6769,93];

    // Account Factory system
    PortfolioFactory public portfolioFactory = PortfolioFactory(0x52d43C377e498980135C8F2E858f120A18Ea96C2 );

    function setUp() public {
        fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork);
        // vm.startPrank(owner);
        // user = votingEscrow.ownerOf(tokenId);
        // PharaohLoanV2 loanImpl = new PharaohLoanV2();
        // PharaohLoanV2(address(loan)).upgradeToAndCall(address(loanImpl), new bytes(0));
 

        // XPharaohDeploy deployer = new XPharaohDeploy();
        // (XPharaohLoan _xloan, , ,AccountConfigStorage _accountConfigStorage, PortfolioFactory _portfolioFactory) = deployer.mock();
        
        // accountConfigStorage = _accountConfigStorage;
        // portfolioFactory = _portfolioFactory;
        // xloan = XPharaohLoan(address(_xloan));
        // console.log("xloan:", address(xloan));
        // console.log("portfolioFactory:", address(portfolioFactory));

        // // Accept ownership of the deployed cont
        // xloan.acceptOwnership();
        // accountConfigStorage.acceptOwnership();
        


        // address[] memory pool = new address[](1);
        // pool[0] = address(0x1a2950978E29C5e590C77B0b6247beDbFB0b4185);
        // xloan.setApprovedPools(pool, true);
        // // Set up account configuration to approve the loan contract

        // PharaohVault vaultImpl = new PharaohVault();
        // vault.upgradeToAndCall(address(vaultImpl), new bytes(0));

    }


// Token: vePHARTokenId: 3818
    function testMigrationOwner() public {

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 100;
        tokenIds[1] = 108;
        // tokenIds[4] = 5510;
        // token_ids=(3802 6457 4554 6530 5510)

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            address owner = votingEscrow.ownerOf(tokenId);
            console.log("owner:", owner);
            console.log("tokenId:", tokenId);

            (uint256 oldBalance, address oldBorrower) = loan.getLoanDetails(tokenId);
            console.log("oldBorrower:", oldBorrower);
            console.log("oldBalance:", oldBalance);

            // get locked amount of the NFT
            int128 amountLocked = votingEscrow.locked(tokenId).amount;
            console.log("amountLocked (6 decimals):", uint256(uint128(amountLocked)) / 1e12);
            console.log("expectedXPHAR", uint256(uint128(amountLocked)) * 5000 / 1e18);
            vm.prank(IVotingEscrow(address(0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F)).ownerOf(tokenId));
            address userPortfolio = portfolioFactory.portfolioOf(oldBorrower);
            console.log("userPortfolio:", userPortfolio);
            (uint256 oldXBalance, address oldXBorrower) = xloan.getLoanDetails(userPortfolio);
            console.log("oldXBorrower:", oldXBorrower);
            console.log("oldXBalance:", oldXBalance);

            vm.prank(PharaohLoanV2(address(loan)).owner());
            loan.migrateNft(tokenId, address(xloan), address(portfolioFactory));        

            userPortfolio = portfolioFactory.portfolioOf(oldBorrower);
            console.log("userPortfolio:", userPortfolio);
            (uint256 newXBalance, address newXBorrower) = xloan.getLoanDetails(userPortfolio);
            console.log("newXBorrower:", newXBorrower);
            console.log("newXBalance:", newXBalance);
            console.log("-----");
        }
    }

    function testMigration() public {
        address depositer = 0x9a453ee686a2356F2008D59b11Dc5F9e32cB9d77;
        vm.startPrank(0xEe7aE85f2Fe2239E27D9c1E23fFFe168D63b4055);
        uint256 vaultBalance = ERC4626(address(vault)).balanceOf(depositer);
        console.log("vaultBalance:", vaultBalance);
        assertEq(vaultBalance, 0);
        IERC20(address(usdc)).approve(address(vault), 100e6);
        vault.deposit(100e6, depositer);
        vm.stopPrank();
        uint256 totalOutstandingCollateral = 0;
        uint256 totalUnpaidFees = 0;
        uint256 totalBalance = 0;

        address testOwner;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 tokenId = tokens[i];
            if(IVotingEscrow(address(0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F)).ownerOf(tokenId) == address(0)) {
                continue;
            }

            (uint256 outstandingCapital, uint256 unpaidFees, uint256 balance) = PharaohLoanV2(address(loan)).getOutstandingCapital(tokens[i]);
            totalOutstandingCollateral += outstandingCapital;
            totalUnpaidFees += unpaidFees;
            totalBalance += balance;
            uint256 xOutstandingCapital = XPharaohLoan(address(xloan)).activeAssets();
            vm.startPrank(owner);
            (uint256 beginningBalance ,address _user) = PharaohLoanV2(address(loan)).getLoanDetails(tokenId);

            if(beginningBalance > 100e6) {
                testOwner = _user;
            }
            address _xrex = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
            

            address userPortfolio = portfolioFactory.portfolioOf(_user);
            uint256 beginningXPharBalance;
            if(userPortfolio != address(0)) {
                beginningXPharBalance = IERC20(address(_xrex)).balanceOf(userPortfolio);
            }
            
            int128 amountLocked = IVotingEscrow(address(0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F)).locked(tokenId).amount;

            PharaohLoanV2(address(loan)).migrateNft(tokenId, address(xloan), address(portfolioFactory));


            // get XREX Balance of the user portfolio
            userPortfolio = portfolioFactory.portfolioOf(_user);
            uint256 endindXPHARBalance = IERC20(address(_xrex)).balanceOf(userPortfolio);
            (uint256 postBalance,) = XPharaohLoan(address(xloan)).getLoanDetails(user);


            vm.stopPrank();
            address[] memory pool = new address[](1);
            pool[0] = address(0x5cA009013F6B898D134b6798B336A4592f3B4aF2);
            uint256[] memory weights = new uint256[](1);
            weights[0] = 100e18;
            vm.prank(_user);
            XPharaohFacet(userPortfolio).xPharUserVote(address(xloan), pool, weights);

            xOutstandingCapital = XPharaohLoan(address(xloan)).activeAssets();
        }


        uint256 newOutstandingCollateral = xloan.activeAssets();
        uint256 oldOutstandingCollateral = PharaohLoanV2(address(loan)).activeAssets();
        assertEq(newOutstandingCollateral, totalOutstandingCollateral);

        uint256 vaultBalance2 = ERC4626(address(vault)).balanceOf(depositer);
        console.log("vaultBalance:", vaultBalance2);


        vm.startPrank(depositer);
        
        vault.withdraw(ERC4626(address(vault)).maxWithdraw(depositer), depositer, depositer);
        vm.stopPrank();

        assertTrue(IERC20(address(usdc)).balanceOf(depositer) >= 99.9999e6);


        vm.startPrank(owner);
        vault.setLoanContract(address(xloan));
        vm.stopPrank();



        // try requesting loan
        address PHAR = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
        vm.prank(0x972698bF61E2377B5c45B3038D85d04981ddb48c);
        IERC20(PHAR).transfer(depositer, 10000e18);
        address depositerPortfolio = portfolioFactory.portfolioOf(depositer);
        if(depositerPortfolio == address(0)) {
            portfolioFactory.createAccount(depositer);
            depositerPortfolio = portfolioFactory.portfolioOf(depositer);
        }
        uint256 amount = 1e6;
        vm.startPrank(depositer);
        IERC20(PHAR).approve(depositerPortfolio, 10000e18);
        XPharaohFacet(depositerPortfolio).xPharRequestLoan(
            IERC20(PHAR).balanceOf(depositer),
            address(xloan),
            0,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );
        vm.stopPrank();


        vm.startPrank(testOwner);
        //  get loan details
        address testOwnerPortfolio = portfolioFactory.portfolioOf(testOwner);
        (uint256 testOwnerBalance, address testOwnerBorrower) = XPharaohLoan(address(xloan)).getLoanDetails(testOwnerPortfolio);
        IERC20(PHAR).approve(testOwnerPortfolio, IERC20(PHAR).balanceOf(testOwner));
        uint256 testOwnerBalancePHAR = IERC20(PHAR).balanceOf(testOwner);
        vm.expectRevert();
        XPharaohFacet(testOwnerPortfolio).xPharRequestLoan(
            testOwnerBalancePHAR,
            address(xloan),
            0,
            IXLoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false
        );

        vm.expectRevert();
        XPharaohFacet(testOwnerPortfolio).xPharIncreaseLoan(
            address(xloan),
            1
        );


        
        (uint256 testOwnerBalance2, address testOwnerBorrower2) = XPharaohLoan(address(xloan)).getLoanDetails(testOwnerPortfolio);
        assertEq(testOwnerBalance2, testOwnerBalance);
        assertEq(testOwnerBorrower2, testOwnerBorrower);
        vm.stopPrank();
    }


}

// cast calldata "migrateNft(uint256,address,address)" $tokenId 0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C 0x52d43C377e498980135C8F2E858f120A18Ea96C2

// {
//   "chainId": "43114",
//   "transactions": [
//     {
//       "to": "0xf6a044c3b2a3373ef2909e2474f3229f23279b5f",
//       "value": "0",
//       "data": "0x81e9490d00000000000000000000000000000000000000000000000000000000000019130000000000000000000000006bf2fe80d245b06f6900848ec52544fbde6c8d2c00000000000000000000000052d43c377e498980135c8f2e858f120a18ea96c2"
//     },
//     {
//       "to": "0xf6a044c3b2a3373ef2909e2474f3229f23279b5f",
//       "value": "0",
//       "data": "0x81e9490d00000000000000000000000000000000000000000000000000000000000019130000000000000000000000006bf2fe80d245b06f6900848ec52544fbde6c8d2c00000000000000000000000052d43c377e498980135c8f2e858f120a18ea96c2"
//     }
//   ]
// }

contract PortfolioListTest is Test {
    address[] public supportedTokens;
    uint256 fork;
    AccountConfigStorage _accountConfigStorage = AccountConfigStorage(0x17cd3c65daf5b2F806d053D948Ad7d59191fd397);
    FacetRegistry _facetRegistry = FacetRegistry(0x9bCa68D9c613Dc9B07B2727c28b5ce46204943de);
    PortfolioFactory _portfolioFactory = PortfolioFactory(0x52d43C377e498980135C8F2E858f120A18Ea96C2);
    Loan _loan = Loan(0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C);



    function testSOmething() public {
        uint256 fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork);

        address[] memory portfolios = _portfolioFactory.getAllPortfolios();

        for (uint256 i; i < portfolios.length; i++) {
            address owner = _portfolioFactory.ownerOf(portfolios[i]);
            console.log(",", portfolios[i]);
            // XPharaohFacet(payable(portfolios[i])).xPharVote(address(_loan));
        }
        uint256[2] memory allocations = [uint256(197107), uint256(0)];

        // address[] memory fees = new address[](1);
        // fees[0] = address(0xB9Ac36505a0537CaF30217Ee0b65362AED95367A);

        // address[][] memory tokens = new address[][](1);
        // tokens[0] = new address[](2);
        // tokens[0][0] = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
        // tokens[0][1] = address(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
        
        // vm.prank(IOwnable(address(_accountConfigStorage)).owner());
        // _accountConfigStorage.setAuthorizedCaller(0xf161e7c79e0c0A3FD8D75A05A53A04E05B2034d3, true);

        //  vm.prank(0xf161e7c79e0c0A3FD8D75A05A53A04E05B2034d3);
        //  AccountConfigStorage accountConfigStorage = XPharaohFacet(0x727A4f4D1CA9963adFea869846CFa19e536F1749)._accountConfigStorage();
        //  console.log(address(accountConfigStorage));
    }


}