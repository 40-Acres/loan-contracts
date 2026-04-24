// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISuperNovaVoter {
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;
    function reset(uint256 _tokenId) external;
    function poolVoteLength(uint256 tokenId) external view returns (uint256);
    function poolVote(uint256 tokenId, uint256 index) external view returns (address);
    function lastVoted(uint256 id) external view returns (uint256);
}

/**
 * @title LiveSuperNovaMarketplaceNoLoan
 * @dev Fork test against Ethereum mainnet verifying that the SuperNova marketplace
 *      (listing + purchase) functions correctly in a COLLATERAL-ONLY deployment:
 *        - LoanConfig is deployed and linked on PortfolioFactoryConfig
 *        - VotingConfig is deployed and linked on PortfolioFactoryConfig
 *        - `loanContract` is NEVER set (address(0))
 *        - No vault is deployed
 *
 *      The audit of BaseMarketplaceFacet confirms the debt-payment path inside
 *      `receiveSaleProceeds` is gated by `totalDebt > 0`, and that
 *      `CollateralManager.getRequiredPaymentForCollateralRemoval` returns 0
 *      early when `debt == 0`. Therefore:
 *        - `getDebtToken()` (which would revert on a zero loanContract) is NEVER called.
 *        - Buyers can purchase listings and receive the veNFT without touching any
 *          lending infrastructure.
 *
 *      Run:
 *        FOUNDRY_PROFILE=fork forge test --match-path \
 *          test/fork/portfolio_account/live/LiveSuperNovaMarketplaceNoLoan.t.sol -vv
 */
contract LiveSuperNovaMarketplaceNoLoan is Test {
    // SuperNova / Ethereum Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // Known-live SuperNova pool — used to exercise the next-epoch reset path
    address public constant KNOWN_POOL = 0xf2C6E60B0Bae3a9e129F575Ef6001D7300De3a83;

    address public seller = address(0x5e11e4);
    address public buyer = address(0xb0b0b0);
    address public authorizedCaller = address(0xaaaaa);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LoanConfig public loanConfig;
    VotingConfig public votingConfig;
    PortfolioMarketplace public marketplace;

    address public sellerAccount;
    address public buyerAccount;

    ISuperNovaVoter public voter = ISuperNovaVoter(VOTER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        // Deploy factory with the task-specified salt
        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("supernova-marketplace-noloan-test"))
        );
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        // Deploy PortfolioFactoryConfig
        portfolioFactoryConfig = PortfolioFactoryConfig(address(new ERC1967Proxy(
            address(new PortfolioFactoryConfig()),
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER, address(portfolioFactory)))
        )));

        // Deploy VotingConfig and LoanConfig — both linked to the factory config,
        // but NO loanContract is set and NO vault is deployed.
        votingConfig = VotingConfig(address(new ERC1967Proxy(
            address(new VotingConfig()),
            abi.encodeCall(VotingConfig.initialize, (DEPLOYER))
        )));
        loanConfig = LoanConfig(address(new ERC1967Proxy(
            address(new LoanConfig()),
            abi.encodeCall(LoanConfig.initialize, (DEPLOYER, 20_00, 5_00, 1_00))
        )));

        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));
        // INTENTIONALLY SKIPPED: portfolioFactoryConfig.setLoanContract(...)

        loanConfig.setRewardsRate(11300);
        loanConfig.setMultiplier(100);

        // Deploy PortfolioMarketplace and allow USDC as a payment token
        marketplace = new PortfolioMarketplace(
            address(portfolioManager), VOTING_ESCROW, 100, DEPLOYER, DEPLOYER
        );
        marketplace.setAllowedPaymentToken(USDC, true);

        vm.stopPrank();

        // Link config to factory (PM owner operation)
        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Register facets: Collateral + BlackholeVotingEscrow + Voting + BlackholeMarketplace
        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);
        _registerCollateralFacet();
        _registerVotingEscrowFacet();
        _registerVotingFacet();
        _registerMarketplaceFacet();

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        // Create seller + buyer portfolio accounts
        sellerAccount = portfolioFactory.createAccount(seller);
        buyerAccount = portfolioFactory.createAccount(buyer);

        vm.label(VOTING_ESCROW, "veNOVA");
        vm.label(VOTER, "VoterV3");
        vm.label(address(marketplace), "PortfolioMarketplace");
        vm.label(sellerAccount, "SellerAccount");
        vm.label(buyerAccount, "BuyerAccount");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // INVARIANT: confirm the no-loan configuration holds
        assertEq(
            portfolioFactoryConfig.getLoanContract(),
            address(0),
            "loanContract must be address(0) in no-loan deployment"
        );
    }

    // ── Facet registration ──

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
        sel[10] = BaseCollateralFacet.getLTVRatio.selector;
        facetRegistry.registerFacet(address(facet), sel, "CollateralFacet");
    }

    function _registerVotingEscrowFacet() internal {
        BlackholeVotingEscrowFacet facet = new BlackholeVotingEscrowFacet(
            address(portfolioFactory), VOTING_ESCROW, VOTER
        );
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        sel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        sel[2] = BlackholeVotingEscrowFacet.merge.selector;
        sel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        sel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingEscrowFacet");
    }

    function _registerVotingFacet() internal {
        VotingFacet facet = new VotingFacet(
            address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER
        );
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
        BlackholeMarketplaceFacet facet = new BlackholeMarketplaceFacet(
            address(portfolioFactory), VOTING_ESCROW, address(marketplace), VOTER
        );
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

    // ── Helpers ──

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

    function _voteOnPool(uint256 tokenId) internal {
        vm.prank(DEPLOYER);
        votingConfig.setApprovedPool(KNOWN_POOL, true);

        address[] memory pools = new address[](1);
        pools[0] = KNOWN_POOL;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        _singleMulticall(
            seller,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Tests — each mirrors a test in LiveSuperNovaMarketplace with the
    // `_noLoan` suffix, plus one bespoke assertion for the debt-path skip.
    // ─────────────────────────────────────────────────────────────────

    /// @notice makeListing then cancelListing with no loan contract.
    ///         Exercises the listing lifecycle without ever touching
    ///         PortfolioFactoryConfig.getDebtToken() (which would revert
    ///         on a zero loanContract).
    function testMakeAndCancelListing_noLoan() public {
        uint256 tokenId = _createLockInAccount(seller, 1000e18);

        uint256 price = 50e6;
        uint256 nonce = _makeListing(tokenId, price);

        // Listing exists on marketplace with correct fields
        PortfolioMarketplace.Listing memory listing = marketplace.getListing(tokenId);
        assertEq(listing.owner, sellerAccount, "seller portfolio owns listing");
        assertEq(listing.tokenId, tokenId, "listing token id matches");
        assertEq(listing.price, price, "listing price matches");
        assertEq(listing.paymentToken, USDC, "payment token set");
        assertEq(listing.nonce, nonce, "nonce captured");

        // Local sale authorization mirrors listing
        (uint256 authPrice, address authToken) =
            BlackholeMarketplaceFacet(sellerAccount).getSaleAuthorization(tokenId);
        assertEq(authPrice, price, "local auth price");
        assertEq(authToken, USDC, "local auth token");
        assertTrue(
            BlackholeMarketplaceFacet(sellerAccount).hasSaleAuthorization(tokenId),
            "local sale authorization exists"
        );

        // Purchasable: no debt → net payment (>= 0) is sufficient
        (bool purchasable, uint256 requiredPayment, uint256 netPayment) =
            BlackholeMarketplaceFacet(sellerAccount).isListingPurchasable(tokenId);
        assertTrue(purchasable, "listing purchasable with no debt");
        assertEq(requiredPayment, 0, "no required debt payment in no-loan config");
        assertGt(netPayment, 0, "non-zero net payment after fee");

        // Cancel listing
        _singleMulticall(
            seller,
            abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, tokenId)
        );

        // Both centralized and local state cleared
        PortfolioMarketplace.Listing memory afterCancel = marketplace.getListing(tokenId);
        assertEq(afterCancel.owner, address(0), "centralized listing cleared");
        assertFalse(
            BlackholeMarketplaceFacet(sellerAccount).hasSaleAuthorization(tokenId),
            "local authorization cleared"
        );

        // Seller account still owns the veNFT (cancel must not move it)
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            sellerAccount,
            "veNFT remains with seller after cancel"
        );
    }

    /// @notice End-to-end purchase when seller's veNFT has NO votes.
    ///         Mirrors `testBuyListing_noVotes` but with no loan contract.
    function testBuyListing_noVotes_noLoan() public {
        uint256 tokenId = _createLockInAccount(seller, 1000e18);

        assertFalse(
            IBlackholeVE(VOTING_ESCROW).voted(tokenId),
            "fresh token should not be voted"
        );

        uint256 price = 50e6;
        uint256 nonce = _makeListing(tokenId, price);

        // Capture balances and expected net payment before buy
        uint256 sellerUsdcBefore = IERC20(USDC).balanceOf(seller);
        uint256 buyerUsdcBefore = IERC20(USDC).balanceOf(buyer); // 0 before deal
        uint256 feeRecipientBefore = IERC20(USDC).balanceOf(DEPLOYER);

        uint256 feeBps = marketplace.protocolFeeBps();
        uint256 fee = (price * feeBps) / 10000;
        uint256 netPaymentExpected = price - fee;

        _buyListing(tokenId, nonce, price);

        // veNFT transferred to buyer EOA (buyerPortfolio arg on purchaseListing
        // is the caller, i.e. the buyer EOA in this flow).
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            buyer,
            "buyer receives veNFT"
        );

        // Seller EOA receives the full net payment (no debt → all proceeds to owner)
        uint256 sellerUsdcAfter = IERC20(USDC).balanceOf(seller);
        assertEq(
            sellerUsdcAfter - sellerUsdcBefore,
            netPaymentExpected,
            "seller receives full net payment (no debt repayment)"
        );

        // Buyer paid exactly `price` — dealt `price`, ends with `buyerUsdcBefore`
        uint256 buyerUsdcAfter = IERC20(USDC).balanceOf(buyer);
        assertEq(buyerUsdcAfter, buyerUsdcBefore, "buyer spent the full price");

        // Fee recipient received the protocol fee
        uint256 feeRecipientAfter = IERC20(USDC).balanceOf(DEPLOYER);
        assertEq(
            feeRecipientAfter - feeRecipientBefore,
            fee,
            "fee recipient receives protocol fee"
        );

        // Seller portfolio's debt remains 0 — the debt-payment branch was skipped
        assertEq(
            ICollateralFacet(sellerAccount).getTotalDebt(),
            0,
            "seller totalDebt remains 0"
        );

        // Local + centralized listing state both cleared
        assertFalse(
            BlackholeMarketplaceFacet(sellerAccount).hasSaleAuthorization(tokenId),
            "sale authorization cleared post-purchase"
        );
        assertEq(
            marketplace.getListing(tokenId).owner,
            address(0),
            "centralized listing cleared post-purchase"
        );

        // Seller's collateral tracking for this tokenId is cleared
        assertEq(
            BaseCollateralFacet(sellerAccount).getLockedCollateral(tokenId),
            0,
            "locked collateral cleared after sale"
        );
    }

    /// @notice Mirrors `testBuyListing_nextEpoch_autoResetSucceeds`:
    ///         Seller votes in epoch N, time advances to N+1, then a buyer
    ///         purchases. BlackholeMarketplaceFacet._prepareTokenForTransfer()
    ///         auto-calls voter.reset() which succeeds in the next epoch.
    ///         Verifies the flow works in the collateral-only (no loan) config.
    function testBuyListing_nextEpoch_autoResetSucceeds_noLoan() public {
        uint256 tokenId = _createLockInAccount(seller, 1000e18);

        // Vote in the current epoch
        _voteOnPool(tokenId);
        assertTrue(
            IBlackholeVE(VOTING_ESCROW).voted(tokenId),
            "token should be voted after _voteOnPool"
        );

        // Advance a full epoch so voter.reset() is allowed
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400);

        // List + confirm purchasable after epoch flip
        uint256 price = 50e6;
        uint256 nonce = _makeListing(tokenId, price);

        (bool purchasable, uint256 requiredPayment, uint256 netPayment) =
            BlackholeMarketplaceFacet(sellerAccount).isListingPurchasable(tokenId);
        assertTrue(purchasable, "purchasable after next-epoch flip");
        assertEq(requiredPayment, 0, "no required debt payment in no-loan config");
        assertGt(netPayment, 0, "non-zero net payment");

        // Snapshot balances for delta assertions
        uint256 sellerUsdcBefore = IERC20(USDC).balanceOf(seller);
        uint256 feeBps = marketplace.protocolFeeBps();
        uint256 expectedNet = price - (price * feeBps) / 10000;

        _buyListing(tokenId, nonce, price);

        // veNFT now owned by buyer
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            buyer,
            "buyer owns veNFT after auto-reset purchase"
        );

        // Seller received full net payment
        assertEq(
            IERC20(USDC).balanceOf(seller) - sellerUsdcBefore,
            expectedNet,
            "seller receives full net payment in no-loan config"
        );

        // Debt untouched
        assertEq(ICollateralFacet(sellerAccount).getTotalDebt(), 0, "seller debt remains 0");
    }

    /// @notice Extra test required by the task. Proves the debt-payment path
    ///         inside BaseMarketplaceFacet.receiveSaleProceeds is SKIPPED when
    ///         totalDebt == 0. In the no-loan config, if the debt path were
    ///         entered it would call PortfolioFactoryConfig.getDebtToken(),
    ///         which dereferences a zero loanContract and reverts. Success of
    ///         this test proves the `totalDebt > 0` gate works correctly.
    function testPurchase_noDebtPathSkipped_noLoan() public {
        uint256 tokenId = _createLockInAccount(seller, 1000e18);

        // Pre-condition: seller has zero debt (no loan contract ever wired up)
        uint256 debtBefore = ICollateralFacet(sellerAccount).getTotalDebt();
        assertEq(debtBefore, 0, "seller starts with zero debt");

        uint256 price = 50e6;
        uint256 nonce = _makeListing(tokenId, price);

        uint256 feeBps = marketplace.protocolFeeBps();
        uint256 expectedNet = price - (price * feeBps) / 10000;

        uint256 sellerUsdcBefore = IERC20(USDC).balanceOf(seller);

        // If receiveSaleProceeds entered the debt branch, getDebtToken() would
        // revert on a zero loanContract. This call succeeding is the proof.
        _buyListing(tokenId, nonce, price);

        // Post-condition: debt still 0
        uint256 debtAfter = ICollateralFacet(sellerAccount).getTotalDebt();
        assertEq(debtAfter, 0, "seller debt remains 0 after sale");

        // Seller EOA receives the FULL netPayment (nothing diverted to debt repayment)
        assertEq(
            IERC20(USDC).balanceOf(seller) - sellerUsdcBefore,
            expectedNet,
            "seller EOA receives the full net payment; no debt diversion"
        );

        // veNFT transferred cleanly to buyer
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            buyer,
            "buyer owns the veNFT"
        );

        // Seller portfolio no longer has any locked collateral for this token
        assertEq(
            BaseCollateralFacet(sellerAccount).getLockedCollateral(tokenId),
            0,
            "locked collateral cleared"
        );
        assertEq(
            ICollateralFacet(sellerAccount).getTotalLockedCollateral(),
            0,
            "total locked collateral back to 0"
        );

        // Seller portfolio should hold no residual USDC — proceeds forwarded to owner
        assertEq(
            IERC20(USDC).balanceOf(sellerAccount),
            0,
            "seller portfolio holds no leftover USDC"
        );
    }
}
