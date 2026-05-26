// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {console} from "forge-std/console.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {VeHydrexFacet} from "../../../src/facets/account/veHydrex/VeHydrexFacet.sol";
import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {HydrexCollateralFacet} from "../../../src/facets/account/veHydrex/HydrexCollateralFacet.sol";
import {HydrexLendingFacet} from "../../../src/facets/account/veHydrex/HydrexLendingFacet.sol";
import {HydrexRewardsProcessingFacet} from "../../../src/facets/account/veHydrex/HydrexRewardsProcessingFacet.sol";

import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";

import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {console} from "forge-std/console.sol";

/**
 * @dev Deploys a Hydrex portfolio diamond against the SIMPLE collateral path:
 *      HydrexCollateralManager (locally-tracked debt) borrowing from a fresh
 *      LoanV2 + VaultV2 pair, USDC-denominated, on Base.
 *
 *      Curve params (set via LoanConfig.setLenderPremiumCurve after init):
 *        base   = 2000  (20% baseline lender share)
 *        slope  = 2550  (25.5% per 100% util past kink)
 *        kink   = 25000 (kink at 250% per-borrower LTV)
 *        cap    = 9000  (90% combined cap)
 *        treasury = 500 (5% protocol)
 */
contract VeHydrexSimpleDeploy is PortfolioFactoryConfigDeploy {
    // PortfolioFactory + FacetRegistry already deployed by the multisig
    // (via portfolioManager.deployFactory) under salt keccak256("hydrex-usdc").
    // Exposed as virtual getters so fork tests can override them to point at
    // a freshly-deployed pair without touching the script's deploy logic.
    function portfolioFactoryAddress() public view virtual returns (address) {
        return 0x74488Ee5f1599CC4b89Fa42134b9c5a142Cba7D6;
    }

    function facetRegistryAddress() public view virtual returns (address) {
        return 0x60Ab719aa7e0De6797e1619FCeACaB29C2A9E24b;
    }

    // Base chain external addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant HYDREX_VOTING_ESCROW = 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1;
    address public constant HYDREX_VOTER = 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b;
    address public constant HYDREX_REWARDS_DISTRIBUTOR = 0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42;

    // Lender-premium curve params (per-borrower LTV in bps, output bps)
    uint256 public constant CURVE_BASE = 2_000;
    uint256 public constant CURVE_SLOPE = 2_550;
    uint256 public constant CURVE_KINK = 25_000;
    uint256 public constant CURVE_CAP = 9_000;
    uint256 public constant TREASURY_BPS = 500;
    uint256 public constant ZERO_BALANCE_FEE_BPS = 100;
    uint256 public constant ORIGINATION_FEE_BPS = 80;

    PortfolioFactory public _portfolioFactory;
    LendingVault public _lendingVault;
    HydrexPortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;

    // Facet addresses (populated by _deploy). Exposed so fork tests can drive
    // the multisig-side facet-registry calls (Phase C) without re-deploying.
    address public claimingFacet;
    address public collateralFacet;
    address public lendingFacet;
    address public votingFacet;
    address public votingEscrowFacet;
    address public rewardsProcessingFacet;
    address public rewardsConfigFacet;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        SwapConfig swapConfig = SwapConfig(BASE_SWAP_CONFIG);

        PortfolioFactory portfolioFactory = PortfolioFactory(portfolioFactoryAddress());
        FacetRegistry facetRegistry = FacetRegistry(facetRegistryAddress());
        require(address(portfolioFactory.facetRegistry()) == facetRegistryAddress(), "FacetRegistry mismatch");
        _portfolioFactory = portfolioFactory;

        // Hydrex-specific config (rebase-bucket slot lives here).
        HydrexPortfolioFactoryConfig configImpl = new HydrexPortfolioFactoryConfig();
        _portfolioFactoryConfig = HydrexPortfolioFactoryConfig(
            address(
                new ERC1967Proxy(
                    address(configImpl),
                    abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER_ADDRESS, address(portfolioFactory)))
                )
            )
        );

        // LoanConfig — initial flat lenderPremium=CURVE_BASE is the value the
        // curve returns at low LTV. Curve enabled below via setLenderPremiumCurve.
        LoanConfig loanConfigImpl = new LoanConfig();
        _loanConfig = LoanConfig(
            address(
                new ERC1967Proxy(
                    address(loanConfigImpl),
                    abi.encodeCall(
                        LoanConfig.initialize, (DEPLOYER_ADDRESS, CURVE_BASE, TREASURY_BPS, ZERO_BALANCE_FEE_BPS)
                    )
                )
            )
        );
        _loanConfig.setLenderPremiumCurve(CURVE_BASE, CURVE_SLOPE, CURVE_KINK, CURVE_CAP);

        // VotingConfig — fresh, deployer-owned.
        VotingConfig votingConfigImpl = new VotingConfig();
        _votingConfig = VotingConfig(address(new ERC1967Proxy(address(votingConfigImpl), "")));
        _votingConfig.initialize(DEPLOYER_ADDRESS);
        _votingConfig.setApprovedPools(_initialApprovedPools(), true);

        // Fresh LendingVault (single ERC4626 contract that also implements ILendingPool).
        LendingVault vaultImpl = new LendingVault();
        _lendingVault = LendingVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        LendingVault.initialize,
                        (
                            USDC,
                            address(portfolioFactory),
                            DEPLOYER_ADDRESS,
                            "40ACRES-HYDREX-USDC-VAULT",
                            "40ACRES-HYDREX-USDC",
                            ORIGINATION_FEE_BPS
                        )
                    )
                )
            )
        );

        _portfolioFactoryConfig.setVoteConfig(address(_votingConfig));
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));
        _portfolioFactoryConfig.setLoanContract(address(_lendingVault));
        // portfolioFactory.setPortfolioFactoryConfig(...) is multisig-gated (PortfolioManager.owner).
        // The multisig must call it post-deploy with the address logged below.

        claimingFacet = address(new VeHydrexClaimingFacet(
            address(portfolioFactory), HYDREX_VOTING_ESCROW, HYDREX_VOTER, HYDREX_REWARDS_DISTRIBUTOR
        ));
        _registerFacet(facetRegistry, claimingFacet, _claimingSelectors(), "VeHydrexClaimingFacet");

        collateralFacet = address(new HydrexCollateralFacet(address(portfolioFactory), HYDREX_VOTING_ESCROW));
        _registerFacet(facetRegistry, collateralFacet, _collateralSelectors(), "HydrexCollateralFacet");

        lendingFacet = address(new HydrexLendingFacet(address(portfolioFactory), USDC));
        _registerFacet(facetRegistry, lendingFacet, _lendingSelectors(), "HydrexLendingFacet");

        votingFacet = address(new VeHydrexFacet(address(portfolioFactory), address(_votingConfig), HYDREX_VOTING_ESCROW, HYDREX_VOTER));
        _registerFacet(facetRegistry, votingFacet, _votingSelectors(), "VeHydrexFacet");

        votingEscrowFacet = address(new VeHydrexVotingEscrowFacet(address(portfolioFactory), HYDREX_VOTING_ESCROW));
        _registerFacet(facetRegistry, votingEscrowFacet, _votingEscrowSelectors(), "VeHydrexVotingEscrowFacet");

        rewardsProcessingFacet = address(new HydrexRewardsProcessingFacet(
            address(portfolioFactory),
            address(swapConfig),
            HYDREX_VOTING_ESCROW,
            address(_lendingVault),
            IHydrexVotingEscrow(HYDREX_VOTING_ESCROW).token(),
            USDC
        ));
        _registerFacet(
            facetRegistry, rewardsProcessingFacet, _rewardsProcessingSelectors(), "HydrexRewardsProcessingFacet"
        );

        rewardsConfigFacet = address(new RewardsConfigFacet(address(portfolioFactory), address(swapConfig)));
        _registerFacet(facetRegistry, rewardsConfigFacet, _rewardsConfigSelectors(), "RewardsConfigFacet");

        console.log("PortfolioFactory:", address(portfolioFactory));
        // Hand over ownership to the multisig. Ownable2Step requires the multisig
        // to call acceptOwnership() on each contract to finalize the transfer.
        _portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
        _votingConfig.transferOwnership(MULTISIG_ADDRESS);
        _loanConfig.transferOwnership(MULTISIG_ADDRESS);
        _lendingVault.transferOwnership(MULTISIG_ADDRESS);

        console.log("=== Deployed addresses ===");
        console.log("PortfolioFactoryConfig:", address(_portfolioFactoryConfig));
        console.log("LoanConfig:            ", address(_loanConfig));
        console.log("VotingConfig:          ", address(_votingConfig));
        console.log("LendingVault:          ", address(_lendingVault));

        console.log("=== Multisig: setPortfolioFactoryConfig ===");
        console.log("To:  ", portfolioFactoryAddress());
        console.logBytes(
            abi.encodeWithSelector(PortfolioFactory.setPortfolioFactoryConfig.selector, address(_portfolioFactoryConfig))
        );

        console.log("=== Multisig: acceptOwnership (4x) ===");
        console.log("portfolioFactoryConfig:", address(_portfolioFactoryConfig));
        console.log("votingConfig:          ", address(_votingConfig));
        console.log("loanConfig:            ", address(_loanConfig));
        console.log("lendingVault:          ", address(_lendingVault));
        console.logBytes(abi.encodeWithSignature("acceptOwnership()"));

        _writeDeployJson(address(_portfolioFactoryConfig), address(_votingConfig), address(_loanConfig), address(_lendingVault));
    }

    function _writeDeployJson(address portfolioFactoryConfig_, address votingConfig_, address loanConfig_, address lendingVault_) internal {
        string memory json = "vehydrex-simple";
        vm.serializeAddress(json, "portfolioFactory", portfolioFactoryAddress());
        vm.serializeAddress(json, "facetRegistry", facetRegistryAddress());
        vm.serializeAddress(json, "portfolioFactoryConfig", portfolioFactoryConfig_);
        vm.serializeAddress(json, "votingConfig", votingConfig_);
        vm.serializeAddress(json, "loanConfig", loanConfig_);
        string memory finalJson = vm.serializeAddress(json, "lendingVault", lendingVault_);
        vm.writeJson(finalJson, "./script/portfolio_account/veHydrex/deployed/vehydrex-simple.json");
    }

    function _claimingSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = ClaimingFacet.claimFees.selector;
        s[1] = ClaimingFacet.claimRebase.selector;
    }

    function _collateralSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = BaseCollateralFacet.addCollateral.selector;
        s[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        s[2] = BaseCollateralFacet.getTotalDebt.selector;
        s[3] = BaseCollateralFacet.getMaxLoan.selector;
        s[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        s[5] = BaseCollateralFacet.removeCollateral.selector;
        s[6] = BaseCollateralFacet.getCollateralToken.selector;
        s[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        s[8] = BaseCollateralFacet.getLockedCollateral.selector;
        s[9] = BaseCollateralFacet.removeCollateralTo.selector;
        s[10] = BaseCollateralFacet.getLoanUtilization.selector;
    }

    function _lendingSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = BaseLendingFacet.borrow.selector;
        s[1] = BaseLendingFacet.pay.selector;
        s[2] = BaseLendingFacet.setTopUp.selector;
        s[3] = BaseLendingFacet.topUp.selector;
        s[4] = BaseLendingFacet.borrowTo.selector;
    }

    function _votingSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = VeHydrexFacet.vote.selector;
        s[1] = VeHydrexFacet.batchVote.selector;
        s[2] = VeHydrexFacet.setVotingMode.selector;
        s[3] = VeHydrexFacet.isManualVoting.selector;
        s[4] = VeHydrexFacet.defaultVote.selector;
    }

    function _votingEscrowSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = VeHydrexVotingEscrowFacet.increaseLock.selector;
        s[1] = VeHydrexVotingEscrowFacet.createLock.selector;
        s[2] = VeHydrexVotingEscrowFacet.merge.selector;
        s[3] = VeHydrexVotingEscrowFacet.mergeInternal.selector;
        s[4] = VeHydrexVotingEscrowFacet.split.selector;
        s[5] = VeHydrexVotingEscrowFacet.onERC721Received.selector;
    }

    function _rewardsProcessingSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = RewardsProcessingFacet.processRewards.selector;
        s[1] = RewardsProcessingFacet.getRewardsToken.selector;
        s[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        s[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        s[4] = RewardsProcessingFacet.calculateRoutes.selector;
    }

    function _rewardsConfigSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = RewardsConfigFacet.setRecipient.selector;
        s[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        s[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        s[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        s[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        s[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
    }

    /// @dev Hydrex pools (Base) with current-epoch rewards > $100 per hydrex.fi/vote snapshot.
    ///      Selected on-chain by max stable-coin + native-token balances parked on each
    ///      gauge's external_bribes and internal_bribes voting-reward contracts.
    function _initialApprovedPools() internal pure returns (address[] memory pools) {
        pools = new address[](33);
        pools[0]  = 0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2; // HYDX/USDC (Manual)
        pools[1]  = 0xd0a0952146dA2Fe2E3EF5898C60daA8A7bf9d1e9; // MONSTRO/mUSDC
        pools[2]  = 0x18156ACE9940645ebF3602E2B320a77131a70aD1; // BETR/WETH
        pools[3]  = 0x680581725840958141Bb328666D8Fc185aC4FA49; // BNKR/WETH
        pools[4]  = 0xcecf4d16114E601276Ba7E8C39A309fBfc605F0e; // USDC/MRDN
        pools[5]  = 0xb8F9Dbb4a56292811C749e53B7085fdC9856cEC0; // GBM/USDC
        pools[6]  = 0x89867ac9918d514E85d3ad906351Be90780Ce513; // WETH/MILK
        pools[7]  = 0x3f9b863EF4B295d6Ba370215bcCa3785FCC44f44; // WETH/cbBTC
        pools[8]  = 0x7796fc53B75960A9762Ba267c19F5da9868B7853; // wtSPYM/USDC
        pools[9]  = 0x053384cc10819B1519DabB5305Dc4711A00CfDB8; // USDp/frxUSD
        pools[10] = 0xB20f018Dde5A6FE7F93c31Da05a5Da9EfBc52772; // WETH/EURC
        pools[11] = 0x0BA69825c4C033e72309F6AC0Bde0023b15Cc97c; // USDC/cbBTC
        pools[12] = 0x2Df4Af05F8C4AFf0d3FbfC327595dbb7Fc6498BF; // WETH/REPPO
        pools[13] = 0x82dbe18346a8656dBB5E76F74bf3AE279cC16B29; // WETH/USDC
        pools[14] = 0x02107bAb40bBA06AE979A15f67B5AD3853c5E116; // USDC/VVV
        pools[15] = 0x37077D100b369Ab48c9e6B7b21c15eee4fDF9923; // cbBTC/wtMSTR
        pools[16] = 0x6FAe4c404BE7BDd12492385498F8C6e5177e4532; // WETH/MCADE
        pools[17] = 0x4506B0e9a7b0B06185fF317cEF77bc5454B045C9; // FXUSD/USDC
        pools[18] = 0xF19787f048b3401546aa7A979afa79D555C114Dd; // WETH/FACY
        pools[19] = 0x52fde427c2483bA0749140C0B43cfce73ba50D20; // BNKR/FXUSD
        pools[20] = 0x174B0950f7359F6197E92d8B274F0D6B27154575; // USDC/mUSDC
        pools[21] = 0xab5d32fF95b58bD5e77De08738a391973eE88C81; // wtCOIN/USDC
        pools[22] = 0x89F29DD355d74e57389374a2AA5f9518a1e497aC; // HYDX/WETH
        pools[23] = 0x8323bA10155388825Fba72f4c81Dd6642D7321eF; // WETH/SERV
        pools[24] = 0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d; // HYDX/USDC (Classic)
        pools[25] = 0x53ab4c60ff04b782F630A8685af95404f099aAFD; // LFI/USDC
        pools[26] = 0xB3f0828eB3375B609b49E9Fb959472a29cD6E49a; // WETH/TIBBIR
        pools[27] = 0xE19fA51bfAF6cECC9D8B6759cA66dB399188DFa7; // USDC/MCADE
        pools[28] = 0x763ADCf71cB195184088A26BE01662119E303F5f; // AZUSD/USDC
        pools[29] = 0x467a8846E7B54eAC5D4D1cb2FDC9B8752212Ff0e; // WETH/NOCK
        pools[30] = 0xece0d1e0615feB34e78129d1996B75f1ff082324; // wtQQQM/USDC
        pools[31] = 0xd4610403F0a93611ca76a5847743533268efF793; // tGBP/frxUSD
        pools[32] = 0xC3F617c8A3DA6d286c8f97aF946A8f293632C852; // WETH/DEXTF
    }
}

// forge script script/portfolio_account/veHydrex/DeployVeHydrexSimple.s.sol:VeHydrexSimpleDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
