pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {PortfolioFactoryDeploy} from "../../../script/portfolio_account/PortfolioFactoryDeploy.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Loan} from "../../../src/Loan.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../../../src/VaultV2.sol";

contract Setup is Test {
    ClaimingFacet public _claimingFacet;
    PortfolioFactory public _portfolioFactory;

    // config addresses
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    PortfolioAccountConfig public _portfolioAccountConfig;
    PortfolioManager public _portfolioManager;
    SwapConfig public _swapConfig;
    FacetRegistry public _facetRegistry;

    IVotingEscrow public _votingEscrow = IVotingEscrow(0xc93B315971A4f260875103F5DA84cB1E30f366Cc);
    IVoter public _voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    IRewardsDistributor public _rewardsDistributor = IRewardsDistributor(0x227f65131A261548b057215bB1D5Ab2997964C7d);
    IERC20 public _asset = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 public _aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IVotingEscrow public _ve = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    address FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public _aeroFactory = address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    address public _usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public _authorizedCaller = address(0xaaaaa);
    address public _loanContract;
    address public _vault;
    
    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    uint256 public _tokenId = 84297;
    address public _owner = FORTY_ACRES_DEPLOYER;

    function setUp() public virtual {
        uint256 fork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(38869188);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _portfolioManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("aerodrome-usdc"))));
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (PortfolioAccountConfig portfolioAccountConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = configDeployer.deploy();
        _portfolioFactory = portfolioFactory;
        DeployFacets deployer = new DeployFacets();


        // Deploy fresh Loan contract
        Loan loanImplementation = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImplementation), "");
        _loanContract = address(loanProxy);

        deployer.deploy(address(portfolioFactory), address(portfolioAccountConfig), address(votingConfig), address(_ve), address(_voter), address(_rewardsDistributor), address(loanConfig), address(_usdc), address(swapConfig), address(_loanContract));
        vm.stopPrank();

        // create a portfolio account
        _portfolioAccount = portfolioFactory.createAccount(_user);
        _portfolioAccountConfig = portfolioAccountConfig;
        _loanConfig = loanConfig;
        _votingConfig = votingConfig;
        _facetRegistry = facetRegistry;
        _swapConfig = swapConfig;
        
        vm.startPrank(IVotingEscrow(_ve).ownerOf(_tokenId));
        IVotingEscrow(_ve).transferFrom(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount, _tokenId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Set default loan config values
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        setDefaults();
        vm.stopPrank();
    }

    function setDefaults() public {
        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(100);
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);
        
        Vault vaultImplementation = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        Vault vault = Vault(address(vaultProxy));
        
        // Initialize vault
        vault.initialize(address(_usdc), address(_loanContract), "40base-USDC-VAULT", "40base-USDC-VAULT");
        
        // Initialize loan
        Loan(address(_loanContract)).initialize(address(vault), _usdc);
        
        // Upgrade loan to LoanV2
        LoanV2 loanV2Impl = new LoanV2();
        LoanV2 loanV2 = LoanV2(payable(_loanContract));
        loanV2.upgradeToAndCall(address(loanV2Impl), new bytes(0));
        
        // Set portfolio factory on loan contract
        loanV2.setPortfolioFactory(address(_portfolioFactory));
        
        // Store addresses
        _loanContract = address(_loanContract);
        _vault = address(vault);
        
        // Set loan contract in config
        _portfolioAccountConfig.setLoanContract(_loanContract);
    }

}