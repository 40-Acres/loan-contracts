// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";
import {BlackholeMarketplaceFacet} from "../../../../src/facets/account/blackhole/BlackholeMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../../src/facets/marketplace/PortfolioMarketplace.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVotingEscrow as IBlackholeVE} from "../../../../src/Blackhole/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../../src/Blackhole/interfaces/IVoter.sol";
import {ILendingPool} from "../../../../src/interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISuperNovaVoter {
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;
    function reset(uint256 _tokenId) external;
    function poolVoteLength(uint256 tokenId) external view returns (uint256);
    function poolVote(uint256 tokenId, uint256 index) external view returns (address);
    function lastVoted(uint256 id) external view returns (uint256);
}

contract MockLendingPoolMP is ILendingPool {
    address public immutable _lendingAsset;
    address public _portfolioFactory;

    constructor(address lendingAsset_) { _lendingAsset = lendingAsset_; }
    function setPortfolioFactory(address factory) external { _portfolioFactory = factory; }
    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function borrowFromPortfolio(uint256) external pure returns (uint256) { return 0; }
    function payFromPortfolio(uint256 totalPayment, uint256) external pure returns (uint256) { return totalPayment; }
    function lendingAsset() external view returns (address) { return _lendingAsset; }
    function lendingVault() external pure returns (address) { return address(0); }
    function activeAssets() external pure returns (uint256) { return 0; }
    function depositRewards(uint256) external {}
    function setActiveAssets(uint256) external {}
    function getDebtBalance(address) external pure returns (uint256) { return 0; }
    function getEffectiveDebtBalance(address) external pure returns (uint256) { return 0; }
}

/**
 * @title LiveSuperNovaMarketplace
 * @dev Fork test against Ethereum mainnet to reproduce marketplace buy issues on SuperNova.
 *      Tests whether veNOVA tokens can be transferred during a purchase when they have active votes.
 */
contract LiveSuperNovaMarketplace is Test {
    // SuperNova addresses (Ethereum Mainnet)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant REWARDS_DISTRIBUTOR = 0xB3410A30af5033aF822B8eA5Ad3bd0a19490ea97;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    address public seller = address(0x5e11e4);
    address public buyer = address(0xb0b0b0);
    address public authorizedCaller = address(0xaaaaa);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LoanConfig public loanConfig;
    SwapConfig public swapConfig;
    VotingConfig public votingConfig;
    PortfolioMarketplace public marketplace;

    address public sellerAccount;
    address public buyerAccount;

    ISuperNovaVoter public voter = ISuperNovaVoter(VOTER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        // Deploy factory
        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(keccak256(abi.encodePacked("supernova-mp-test")));
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        // Deploy configs
        portfolioFactoryConfig = PortfolioFactoryConfig(address(new ERC1967Proxy(
            address(new PortfolioFactoryConfig()),
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER, address(portfolioFactory)))
        )));
        votingConfig = VotingConfig(address(new ERC1967Proxy(
            address(new VotingConfig()),
            abi.encodeCall(VotingConfig.initialize, (DEPLOYER))
        )));
        loanConfig = LoanConfig(address(new ERC1967Proxy(
            address(new LoanConfig()),
            abi.encodeCall(LoanConfig.initialize, (DEPLOYER, 20_00, 5_00, 1_00))
        )));
        swapConfig = SwapConfig(address(new ERC1967Proxy(
            address(new SwapConfig()),
            abi.encodeCall(SwapConfig.initialize, (DEPLOYER))
        )));
        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        MockLendingPoolMP mockLoan = new MockLendingPoolMP(USDC);
        mockLoan.setPortfolioFactory(address(portfolioFactory));
        portfolioFactoryConfig.setLoanContract(address(mockLoan));

        loanConfig.setRewardsRate(11300);
        loanConfig.setMultiplier(100);

        // Deploy PortfolioMarketplace
        marketplace = new PortfolioMarketplace(
            address(portfolioManager), VOTING_ESCROW, 100, DEPLOYER, DEPLOYER
        );
        marketplace.setAllowedPaymentToken(USDC, true);

        vm.stopPrank();

        // Link config to factory (requires PM owner)
        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Register facets
        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);

        _registerCollateralFacet();
        _registerVotingEscrowFacet();
        _registerVotingFacet();
        _registerMarketplaceFacet();

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        // Create seller and buyer accounts
        sellerAccount = portfolioFactory.createAccount(seller);
        buyerAccount = portfolioFactory.createAccount(buyer);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ---- Facet Registration ----

    function _registerCollateralFacet() internal {
        CollateralFacet facet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = BaseCollateralFacet.addCollateral.selector;
        sel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        sel[2] = BaseCollateralFacet.getTotalDebt.selector;
        sel[3] = BaseCollateralFacet.getMaxLoan.selector;
        sel[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        sel[5] = BaseCollateralFacet.removeCollateral.selector;
        sel[6] = BaseCollateralFacet.getCollateralToken.selector;
        sel[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        sel[8] = BaseCollateralFacet.getLockedCollateral.selector;
        sel[9] = BaseCollateralFacet.removeCollateralTo.selector;
        sel[10] = BaseCollateralFacet.getLoanUtilization.selector;
        facetRegistry.registerFacet(address(facet), sel, "CollateralFacet");
    }

    function _registerVotingEscrowFacet() internal {
        BlackholeVotingEscrowFacet facet = new BlackholeVotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        sel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        sel[2] = BlackholeVotingEscrowFacet.merge.selector;
        sel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        sel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingEscrowFacet");
    }

    function _registerVotingFacet() internal {
        VotingFacet facet = new VotingFacet(address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = VotingFacet.vote.selector;
        sel[1] = VotingFacet.voteForLaunchpadToken.selector;
        sel[2] = VotingFacet.setVotingMode.selector;
        sel[3] = VotingFacet.isManualVoting.selector;
        sel[4] = VotingFacet.defaultVote.selector;
        sel[5] = VotingFacet.batchVote.selector;
        sel[6] = VotingFacet.batchVoteForLaunchpadToken.selector;
        sel[7] = VotingFacet.isElligibleForManualVoting.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingFacet");
    }

    function _registerMarketplaceFacet() internal {
        BlackholeMarketplaceFacet facet = new BlackholeMarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, address(marketplace), VOTER);
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        sel[1] = BaseMarketplaceFacet.makeListing.selector;
        sel[2] = BaseMarketplaceFacet.cancelListing.selector;
        sel[3] = BaseMarketplaceFacet.marketplace.selector;
        sel[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        sel[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        sel[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        sel[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        facetRegistry.registerFacet(address(facet), sel, "MarketplaceFacet");
    }

    // ---- Helpers ----

    function _multicallAs(address user, bytes[] memory calldatas) internal returns (bytes[] memory) {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(portfolioFactory);
        }
        vm.prank(user);
        return portfolioManager.multicall(calldatas, factories);
    }

    function _singleMulticall(address user, bytes memory data) internal returns (bytes[] memory) {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        return _multicallAs(user, calldatas);
    }

    function _createLockInAccount(address user, uint256 amount) internal returns (uint256 tokenId) {
        address account = portfolioFactory.portfolios(user);
        deal(SNOVA_TOKEN, user, amount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(account, amount);
        bytes[] memory results = _singleMulticall(
            user,
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, amount)
        );
        tokenId = abi.decode(results[0], (uint256));
    }

    // Known SuperNova pool (from tokenId 1's poolVote)
    address public constant KNOWN_POOL = 0xf2C6E60B0Bae3a9e129F575Ef6001D7300De3a83;

    function _voteOnPool(uint256 tokenId) internal {
        console.log("Voting on pool:", KNOWN_POOL);

        // Approve pool in VotingConfig
        vm.prank(DEPLOYER);
        votingConfig.setApprovedPool(KNOWN_POOL, true);

        // Vote via multicall
        address[] memory pools = new address[](1);
        pools[0] = KNOWN_POOL;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        _singleMulticall(
            seller,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
    }

    function _makeListing(uint256 tokenId, uint256 price) internal returns (uint256 nonce) {
        _singleMulticall(
            seller,
            abi.encodeWithSelector(
                BaseMarketplaceFacet.makeListing.selector,
                tokenId, price, USDC, uint256(0), address(0)
            )
        );
        PortfolioMarketplace.Listing memory listing = marketplace.getListing(tokenId);
        nonce = listing.nonce;
    }

    function _buyListing(uint256 tokenId, uint256 nonce, uint256 price) internal {
        deal(USDC, buyer, price);
        vm.startPrank(buyer);
        IERC20(USDC).approve(address(marketplace), price);
        marketplace.purchaseListing(tokenId, nonce);
        vm.stopPrank();
    }

    // ---- Tests ----

    /// @notice Baseline: buy a listing when seller's veNFT has NOT voted
    function testBuyListing_noVotes() public {
        uint256 tokenId = _createLockInAccount(seller, 1000e18);

        bool isVoted = IBlackholeVE(VOTING_ESCROW).voted(tokenId);
        console.log("Token voted:", isVoted);
        assertFalse(isVoted, "Token should not be voted initially");

        uint256 price = 50e6;
        uint256 nonce = _makeListing(tokenId, price);
        console.log("Listing created, nonce:", nonce);

        _buyListing(tokenId, nonce, price);

        address newOwner = IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId);
        assertEq(newOwner, buyer, "Buyer should own the veNFT");

        uint256 sellerBalance = IERC20(USDC).balanceOf(seller);
        console.log("Seller received USDC:", sellerBalance);
        assertGt(sellerBalance, 0, "Seller should receive payment");
    }

    /// @notice Same-epoch vote after listing: isListingPurchasable returns false
    function testBuyListing_sameEpochVote_notPurchasable() public {
        uint256 tokenId = _createLockInAccount(seller, 1000e18);

        // Make listing FIRST (before voting)
        uint256 price = 50e6;
        uint256 nonce = _makeListing(tokenId, price);

        // Then vote in the same epoch (e.g. defaultVote by authorized caller)
        _voteOnPool(tokenId);
        assertTrue(IBlackholeVE(VOTING_ESCROW).voted(tokenId), "Token should be voted");

        // isListingPurchasable should return false due to same-epoch vote
        (bool purchasable, , ) = BlackholeMarketplaceFacet(sellerAccount).isListingPurchasable(tokenId);
        assertFalse(purchasable, "Should not be purchasable in same epoch as vote");
        console.log("isListingPurchasable correctly returns false for same-epoch vote");

        // Purchase should revert (voter.reset reverts with "VOTED" in same epoch)
        deal(USDC, buyer, price);
        vm.startPrank(buyer);
        IERC20(USDC).approve(address(marketplace), price);
        vm.expectRevert();
        marketplace.purchaseListing(tokenId, nonce);
        vm.stopPrank();

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), sellerAccount, "NFT still in seller account");
    }

    /// @notice Next-epoch buy: BlackholeMarketplaceFacet auto-resets and transfer succeeds
    function testBuyListing_nextEpoch_autoResetSucceeds() public {
        uint256 tokenId = _createLockInAccount(seller, 1000e18);

        // Vote in current epoch
        _voteOnPool(tokenId);
        assertTrue(IBlackholeVE(VOTING_ESCROW).voted(tokenId), "Should be voted");

        // Warp to next epoch so voter.reset() is allowed
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400);

        // Make listing and buy - BlackholeMarketplaceFacet auto-calls voter.reset()
        uint256 price = 50e6;
        uint256 nonce = _makeListing(tokenId, price);

        // isListingPurchasable should return true (vote was in prior epoch)
        (bool purchasable, , ) = BlackholeMarketplaceFacet(sellerAccount).isListingPurchasable(tokenId);
        assertTrue(purchasable, "Should be purchasable after epoch flip");

        _buyListing(tokenId, nonce, price);

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), buyer, "Buyer should own veNFT");
        console.log("Next-epoch auto-reset buy: OK");
    }

    /// @notice Sanity: direct veNFT transfer without votes succeeds
    function testDirectTransfer_noVotes() public {
        deal(SNOVA_TOKEN, seller, 1000e18);
        vm.startPrank(seller);
        IERC20(SNOVA_TOKEN).approve(VOTING_ESCROW, 1000e18);
        uint256 tokenId = IBlackholeVE(VOTING_ESCROW).create_lock_for(1000e18, 4 * 365 days, seller, false);
        IBlackholeVE(VOTING_ESCROW).transferFrom(seller, buyer, tokenId);
        vm.stopPrank();

        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), buyer);
    }

    /// @notice Sanity: direct veNFT transfer with active votes reverts
    function testDirectTransfer_withVotes_reverts() public {
        deal(SNOVA_TOKEN, seller, 1000e18);
        vm.startPrank(seller);
        IERC20(SNOVA_TOKEN).approve(VOTING_ESCROW, 1000e18);
        uint256 tokenId = IBlackholeVE(VOTING_ESCROW).create_lock_for(1000e18, 4 * 365 days, seller, false);
        vm.stopPrank();

        // Vote directly via voter
        address[] memory pools = new address[](1);
        pools[0] = KNOWN_POOL;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(seller);
        ISuperNovaVoter(VOTER).vote(tokenId, pools, weights);

        assertTrue(IBlackholeVE(VOTING_ESCROW).voted(tokenId), "Should be voted");

        // Transfer should revert
        vm.prank(seller);
        vm.expectRevert();
        IBlackholeVE(VOTING_ESCROW).transferFrom(seller, buyer, tokenId);
    }
}
