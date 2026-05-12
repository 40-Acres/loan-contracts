// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {DeploySuperchainVotingFacet} from "../../../script/portfolio_account/facets/DeploySuperchainVoting.s.sol";
import {DeployClaimingFacet} from "../../../script/portfolio_account/facets/DeployClaimingFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {RootPoolVotingConfig} from "../../../src/facets/account/config/RootPoolVotingConfig.sol";
import {IRootPool} from "../../../src/interfaces/IRootPool.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {Setup} from "../portfolio_account/utils/Setup.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {DeployBridgeFacet} from "../../../script/portfolio_account/facets/DeployBridgeFacet.s.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

import {DeployCollateralFacet} from "../../../script/portfolio_account/facets/DeployCollateralFacet.s.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {Vault} from "../../../src/VaultV2.sol";

contract SuperchainTest is Test, Setup {
    address[] public pools = [address(0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0)];
    uint256[] public weights = [100e18];
    address public launchpadToken = address(0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb);
    address public tokenMessenger = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    RootPoolVotingConfig public _superchainVotingConfig;

    function setUp() public override {
        super.setUp();
    }

    function testSuperchainE2E() public {
        uint256 fork = vm.createFork(vm.envString("OP_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(144334133);

        // USDC address on Optimism fork (different from Base)
        address usdc = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager _pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _pm.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (PortfolioFactoryConfig portfolioFactoryConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = configDeployer.deploy(address(portfolioFactory), FORTY_ACRES_DEPLOYER);

        address ve = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
        address voter = address(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);
        address rewardsDistributor = address(0x9D4736EC60715e71aFe72973f7885DCBC21EA99b);

        RootPoolVotingConfig superchainVotingConfigImpl = new RootPoolVotingConfig();
        bytes memory initData = abi.encodeWithSelector(VotingConfig.initialize.selector, FORTY_ACRES_DEPLOYER);
        ERC1967Proxy superchainVotingConfigProxy = new ERC1967Proxy(address(superchainVotingConfigImpl), initData);
        RootPoolVotingConfig superchainVotingConfig = RootPoolVotingConfig(address(superchainVotingConfigProxy));
        votingConfig = VotingConfig(address(superchainVotingConfigProxy));
        DeploySuperchainVotingFacet deployer = new DeploySuperchainVotingFacet();
        deployer.deploy(address(portfolioFactory), address(superchainVotingConfig), address(ve), address(voter));

        // Deploy base ClaimingFacet (no WETH needed)
        DeployClaimingFacet claimingDeployer = new DeployClaimingFacet();
        claimingDeployer.deploy(address(portfolioFactory), address(ve), address(voter), address(rewardsDistributor), address(loanConfig), address(swapConfig), address(0));

        DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
        deployCollateralFacet.deploy(address(portfolioFactory), address(ve));

        // Deploy fresh Loan contract and Vault
        Loan loanImplementation = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImplementation), "");
        Vault vaultImplementation = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        Vault vault = Vault(address(vaultProxy));

        // Initialize vault
        vault.initialize(usdc, address(loanProxy), "40base-USDC-VAULT", "40base-USDC-VAULT");

        // Initialize loan
        Loan(address(loanProxy)).initialize(address(vault), usdc);

        // Upgrade loan to LoanV2
        LoanV2 loanV2Impl = new LoanV2();
        LoanV2 loanV2 = LoanV2(payable(loanProxy));
        loanV2.upgradeToAndCall(address(loanV2Impl), new bytes(0));

        // Set portfolio factory on loan contract
        loanV2.setPortfolioFactory(address(portfolioFactory));

        // Link factory to config (bidirectional)
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        address loanContract = address(loanProxy);
        portfolioFactoryConfig.setLoanContract(loanContract);

        // Set up authorized caller for claiming
        address authorizedCaller = address(0xaaaaa);
        _pm.setAuthorizedCaller(authorizedCaller, true);

        // Real root pool (implements IRootPool.chainid() → 1868 Soneium).
        // After the migration, superchain pools are identified by the
        // root-pool factory allowlist rather than per-pool. Pull the
        // factory off the live pool and register it. The pool itself
        // still needs the standard VotingConfig approval.
        address superchainPool = 0x21cD02d175D61a4b4D6b62d8707186B1FedaaEAd;
        address rootPoolFactory = IRootPool(superchainPool).factory();
        require(rootPoolFactory != address(0), "pool factory should be non-zero");
        superchainVotingConfig.setRootPoolFactory(rootPoolFactory, true);
        superchainVotingConfig.setApprovedPool(superchainPool, true);

        uint256 tokenId = 5005;

        // Set minimum locked balance per pool based on veNFT's actual locked amount
        int128 lockedAmount = IVotingEscrow(ve).locked(tokenId).amount;
        uint256 lockedBalance = uint256(uint128(lockedAmount));
        superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance / 2);

        vm.stopPrank();

        address user = IVotingEscrow(ve).ownerOf(tokenId);
        vm.startPrank(user, user);
        address portfolioAccount = portfolioFactory.createAccount(user);
        IVotingEscrow(ve).transferFrom(user, portfolioAccount, tokenId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // vote on superchain pool
        address[] memory votePools = new address[](1);
        votePools[0] = superchainPool;
        uint256[] memory voteWeights = new uint256[](1);
        voteWeights[0] = 100e18;

        // Call vote through PortfolioManager multicall
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, tokenId, votePools, voteWeights);

        _pm.multicall(calldatas, portfolioFactories);

        uint256 lastVoted = IVoter(address(voter)).lastVoted(tokenId);
        assertEq(lastVoted, block.timestamp);

        vm.stopPrank();

        // Advance to next epoch before claiming
        uint256 nextEpochStart = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(nextEpochStart + 3 hours);
        vm.roll(block.number + 1);

        // claim for token 5005 using base ClaimingFacet with root pool's reward contracts
        // Fee reward: 0x22796dEA87c141aBEc616E38247074e9e51C6B20
        // Bribe reward: 0x2be8990C7057018b29Da8Af2F5b8c397babB2203
        // Pool tokens: USDT0 (0x0555...) and WETH (0x4200...06)
        address[] memory claimBribes = new address[](2);
        claimBribes[0] = address(0x22796dEA87c141aBEc616E38247074e9e51C6B20);
        claimBribes[1] = address(0x2be8990C7057018b29Da8Af2F5b8c397babB2203);

        address[][] memory claimTokens = new address[][](2);
        claimTokens[0] = new address[](2);
        claimTokens[0][0] = address(0x4200000000000000000000000000000000000006); // WETH
        claimTokens[0][1] = address(0x0555E30da8f98308EdB960aa94C0Db47230d2B9c); // USDT0
        claimTokens[1] = new address[](2);
        claimTokens[1][0] = address(0x4200000000000000000000000000000000000006); // WETH
        claimTokens[1][1] = address(0x0555E30da8f98308EdB960aa94C0Db47230d2B9c); // USDT0

        // Fund authorizedCaller with WETH for Hyperlane cross-chain messaging fees
        address weth = 0x4200000000000000000000000000000000000006;
        address hyperlaneRouter = 0xF278761576f45472bdD721EACA19317cE159c011;
        deal(weth, authorizedCaller, 1 ether);
        vm.startPrank(authorizedCaller, authorizedCaller);
        IERC20(weth).approve(hyperlaneRouter, type(uint256).max);
        ClaimingFacet(portfolioAccount).claimFees(claimBribes, claimTokens, tokenId);
        vm.stopPrank();

        // now mock the 57073 chain and bridge back to optimism
        uint256 inkFork = vm.createFork(vm.envString("INK_RPC_URL"));
        vm.selectFork(inkFork);
        vm.rollFork(30768635);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager ink_pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory ink_portfolioFactory, FacetRegistry ink_facetRegistry) = ink_pm.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        DeployPortfolioFactoryConfig ink_configDeployer = new DeployPortfolioFactoryConfig();
        (PortfolioFactoryConfig ink_portfolioFactoryConfig, VotingConfig ink_votingConfig, LoanConfig ink_loanConfig, SwapConfig ink_swapConfig) = ink_configDeployer.deploy(address(ink_portfolioFactory), FORTY_ACRES_DEPLOYER);

        // deploy the bridge facet
        DeployBridgeFacet ink_deployer = new DeployBridgeFacet();
        ink_deployer.deploy(address(ink_portfolioFactory), address(0x4200000000000000000000000000000000000006), tokenMessenger, address(ink_swapConfig));

        // user should have a balance on WETH and XVELO
        assertEq(IERC20(0x4200000000000000000000000000000000000006).balanceOf(user), 7797992391058710);
        assertEq(IERC20(0x7f9AdFbd38b669F03d1d11000Bc76b9AaEA28A81).balanceOf(user), 96600260079034253069);
    }
}

