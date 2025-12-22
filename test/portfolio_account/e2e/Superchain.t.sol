// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {DeploySuperchainVotingFacet} from "../../../script/portfolio_account/facets/DeploySuperchainVoting.s.sol";
import {DeploySuperchainClaiming} from "../../../script/portfolio_account/facets/DeploySuperchainClaiming.s.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {SuperchainVotingConfig} from "../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {Setup} from "../utils/Setup.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {MockERC20Utils} from "../../utils/MockERC20Utils.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {SuperchainClaimingFacet} from "../../../src/facets/account/claim/SuperchainClaimingFacet.sol";
import {DeployBridgeFacet} from "../../../script/portfolio_account/facets/DeployBridgeFacet.s.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {MockRootVotingRewardsFactory} from "../../mocks/MockRootVotingRewardsFactory.sol";
import {DeployCollateralFacet} from "../../../script/portfolio_account/facets/DeployCollateralFacet.s.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {Vault} from "../../../src/VaultV2.sol";

contract SuperchainTest is Test, Setup, MockERC20Utils {
    address[] public pools = [address(0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0)];
    uint256[] public weights = [100e18];
    address public launchpadToken = address(0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb);
    IERC20 public weth = IERC20(0x4200000000000000000000000000000000000006);
    SuperchainVotingConfig public _superchainVotingConfig;
    MockERC20 public mockWeth;
    address public _rootMessageBridge = 0xF278761576f45472bdD721EACA19317cE159c011;

    function setUp() public override {
        super.setUp();
        // Mock WETH and mint to portfolio account
        address wethAddress = address(0x4200000000000000000000000000000000000006);
        mockWeth = deployAndOverwrite(wethAddress, "Wrapped Ether", "WETH", 18);
    }

    function testSuperchainE2E() public {
        uint256 fork = vm.createFork(vm.envString("OP_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(144334133);
        
        // USDC address on Optimism fork (different from Base)
        address usdc = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
        // Note: We don't make USDC persistent because we'll switch to INK fork where it doesn't exist
        
        // Deploy and overwrite ROOT_VOTING_REWARDS_FACTORY with mock
        address rootVotingRewardsFactoryAddress = address(0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F);
        MockRootVotingRewardsFactory mockFactory = new MockRootVotingRewardsFactory();
        vm.etch(rootVotingRewardsFactoryAddress, address(mockFactory).code);
        
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager _pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _pm.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (PortfolioAccountConfig portfolioAccountConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = configDeployer.deploy();

        address ve = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
        address voter = address(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);
        address rewardsDistributor = address(0x9D4736EC60715e71aFe72973f7885DCBC21EA99b);
        
        
        SuperchainVotingConfig superchainVotingConfigImpl = new SuperchainVotingConfig();
        bytes memory initData = abi.encodeWithSelector(VotingConfig.initialize.selector, FORTY_ACRES_DEPLOYER);
        ERC1967Proxy superchainVotingConfigProxy = new ERC1967Proxy(address(superchainVotingConfigImpl), initData);
        SuperchainVotingConfig superchainVotingConfig = SuperchainVotingConfig(address(superchainVotingConfigProxy));
        votingConfig = VotingConfig(address(superchainVotingConfigProxy));
        DeploySuperchainVotingFacet deployer = new DeploySuperchainVotingFacet();
        deployer.deploy(address(portfolioFactory), address(portfolioAccountConfig), address(superchainVotingConfig), address(ve), address(voter));

        DeploySuperchainClaiming claimingDeployer = new DeploySuperchainClaiming();
        claimingDeployer.deploy(address(portfolioFactory), address(portfolioAccountConfig), address(ve), address(voter), address(rewardsDistributor), address(loanConfig), address(swapConfig), address(0)); // vault - will be set later
        

        DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
        deployCollateralFacet.deploy(address(portfolioFactory), address(portfolioAccountConfig), address(ve));
        
        // Deploy fresh Loan contract and Vault
        // USDC is already marked as persistent above
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
        
        address loanContract = address(loanProxy);
        portfolioAccountConfig.setLoanContract(loanContract);
        // Note: We don't make loan/vault persistent here because they reference USDC
        // and we'll switch to INK fork where USDC doesn't exist
        
        // Set up authorized caller for claiming
        address authorizedCaller = address(0xaaaaa);
        _pm.setAuthorizedCaller(authorizedCaller, true);
        
        superchainVotingConfig.setSuperchainPool(address(0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952), true, 57073);
        superchainVotingConfig.setMinimumWethBalance(.001e18);

        vm.stopPrank();
        uint256 tokenId = 5005;
        
        address user = IVotingEscrow(ve).ownerOf(tokenId);
        vm.startPrank(user, user);
        address portfolioAccount = portfolioFactory.createAccount(user);
        IVotingEscrow(ve).transferFrom(user, portfolioAccount, tokenId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        uint256 preWethBalance = mockWeth.balanceOf(portfolioAccount);

        // vote on superchain pool  0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952
        address[] memory votePools = new address[](1);
        votePools[0] = address(0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952);
        uint256[] memory voteWeights = new uint256[](1);
        voteWeights[0] = 100e18;
        
        // Call vote through PortfolioManager multicall (required by onlyPortfolioManagerMulticall modifier)
        address[] memory portfolios = new address[](1);
        portfolios[0] = portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, tokenId, votePools, voteWeights);
        
        // should revert since user has no WETH
        vm.expectRevert();
        _pm.multicall(calldatas, portfolios);

        // transferWeth to portfolio Account
        IERC20(0x4200000000000000000000000000000000000006).transfer(portfolioAccount, .001e18);
        IERC20(0x4200000000000000000000000000000000000006).transfer(authorizedCaller, .003e18);
        _pm.multicall(calldatas, portfolios);

        uint256 lastVoted = IVoter(address(voter)).lastVoted(tokenId);
        assertEq(lastVoted, block.timestamp);

        // verify WETH was approved to RootMessageBridge
        address rootMessageBridge = _rootMessageBridge;
        uint256 allowance = mockWeth.allowance(address(portfolioAccount), rootMessageBridge);
        assertEq(allowance, .001e18, "WETH should be approved to RootMessageBridge");

        uint256 postWethBalance = mockWeth.balanceOf(portfolioAccount);
        assertEq(postWethBalance, preWethBalance + .001e18, "WETH should be transferred to portfolio account");
        
        vm.stopPrank();

        // Advance to next epoch before claiming
        // The RootMessageBridge checks if token was voted in current epoch and reverts if so
        uint256 nextEpochStart = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(nextEpochStart + 3 hours);
        vm.roll(block.number + 1);

        // claim for token 5005
        address[] memory claimBribes = new address[](2);
        claimBribes[0] = address(0x6c7c646Ff5AFC2D9071aD5f53e879954d815c3F6);
        claimBribes[1] = address(0x554E077BF8201a43C1E1212B33452695B6c8D321);
        
        address[][] memory claimTokens = new address[][](2);
        claimTokens[0] = new address[](2);
        claimTokens[0][0] = address(0x4200000000000000000000000000000000000006);
        claimTokens[0][1] = address(0x7f9AdFbd38b669F03d1d11000Bc76b9AaEA28A81);
        claimTokens[1] = new address[](2);
        claimTokens[1][0] = address(0x7f9AdFbd38b669F03d1d11000Bc76b9AaEA28A81);
        claimTokens[1][1] = address(0x4200000000000000000000000000000000000006);
        
        mockWeth.mint(portfolioAccount, 1e18);
        vm.startPrank(portfolioAccount);
        IERC20(0x4200000000000000000000000000000000000006).approve(address(_rootMessageBridge), type(uint256).max);
        vm.stopPrank();
        
        mockWeth.mint(authorizedCaller, 1e18);
        vm.startPrank(authorizedCaller);
        IERC20(0x4200000000000000000000000000000000000006).approve(address(_rootMessageBridge), type(uint256).max);
        vm.stopPrank();
        console.log("block timestamp: %s", block.timestamp);
        // claimFees requires authorized caller, so we prank as the authorized caller
        assertEq(mockWeth.balanceOf(authorizedCaller), 0.003e18);
        vm.startPrank(authorizedCaller, authorizedCaller);
        SuperchainClaimingFacet(portfolioAccount).claimFees(claimBribes, claimTokens, tokenId);
        vm.stopPrank();

        // authorized caller should have 0.003e18 weth
        assertEq(mockWeth.balanceOf(authorizedCaller), 0.003e18);
        // portfolio account should have less than 0.001e18 weth
        assert(mockWeth.balanceOf(portfolioAccount) < 0.001e18);


        // now mock the 57073 chain and bridge back to optimism
        uint256 inkFork = vm.createFork(vm.envString("INK_RPC_URL"));
        vm.selectFork(inkFork);
        vm.rollFork(30768635);
        // Note: We don't need to make loan/vault/USDC persistent on INK fork
        // since we're deploying fresh infrastructure on this fork and only checking balances
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager ink_pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory ink_portfolioFactory, FacetRegistry ink_facetRegistry) = ink_pm.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        DeployPortfolioAccountConfig ink_configDeployer = new DeployPortfolioAccountConfig();
        (PortfolioAccountConfig ink_portfolioAccountConfig, VotingConfig ink_votingConfig, LoanConfig ink_loanConfig, SwapConfig ink_swapConfig) = ink_configDeployer.deploy();

        // deploy the bridge facet
        // Use WETH address for INK fork (the bridge facet just stores the address, doesn't interact with it in constructor)
        DeployBridgeFacet ink_deployer = new DeployBridgeFacet();
        // Note: Using WETH address here since USDC doesn't exist on INK fork, but BridgeFacet constructor only stores the address
        ink_deployer.deploy(address(ink_portfolioFactory), address(ink_portfolioAccountConfig), address(0x4200000000000000000000000000000000000006));
        

        // user should have a balance on 0x4200000000000000000000000000000000000006 and 0x7f9AdFbd38b669F03d1d11000Bc76b9AaEA28A81 (XVELO)
        assertEq(IERC20(0x4200000000000000000000000000000000000006).balanceOf(user), 7797992391058710);
        assertEq(IERC20(0x7f9AdFbd38b669F03d1d11000Bc76b9AaEA28A81).balanceOf(user), 96600260079034253069);
    }
}

