// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "./utils/DiamondMarketTestBase.t.sol";

import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketOperationsFacet} from "src/interfaces/IMarketOperationsFacet.sol";

// UUPS test dependencies reused for fork context
import {ILoan} from "src/interfaces/ILoan.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";
import {BaseUpgrade} from "script/BaseUpgrade.s.sol";
import {DeploySwapper} from "script/BaseDeploySwapper.s.sol";
import {Swapper} from "src/Swapper.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}


interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}



contract MarketDiamondTest is DiamondMarketTestBase {
    uint256 fork;

    // Mainnet Base addresses used by legacy tests
    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan;
    address owner;
    address user;
    address buyer;
    uint256 tokenId = 72562; // will be overwritten to 349 below
    Swapper public swapper;

    // Test parameters based on real veNFT data
    uint256 constant LISTING_PRICE = 1000e6; // 1000 USDC
    uint256 constant MIN_WEIGHT = 90e21; // min acceptable weight for offers
    uint256 constant MAX_WEIGHT = 100e21; // max acceptable weight for offers
    uint256 constant DEBT_TOLERANCE = 1000e6; // max acceptable loan balance

    function setUp() public {
        // Fork Base mainnet
        fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(24353746);

        // Addresses
        owner = address(this);
        buyer = vm.addr(0x456);

        // Use a known working tokenId on Base
        tokenId = 349;
        user = votingEscrow.ownerOf(tokenId);
        require(user != address(0), "TokenId 349 has no owner");

        // Deploy loan contracts
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();

        // Configure loan contract
        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5%

        // Deploy swapper
        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));

        // Transfer ownership to owner
        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();

        // Accept ownership as owner
        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Deploy diamond and facets
        _deployDiamondAndFacets();

        // Initialize market on diamond
        IMarketConfigFacet(diamond).initMarket(address(loan), address(votingEscrow), 250, owner, address(usdc));

        // Approve diamond as a market contract in loan
        vm.startPrank(owner);
        loan.setApprovedContract(diamond, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), true);
        vm.stopPrank();

        // Set up USDC minting capabilities
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);

        // Mint USDC to vault and users
        usdc.mint(address(vault), 10000e6);

        // Send USDC from real wallet to buyer to ensure they have enough funds
        vm.prank(0x122fDD9fEcbc82F7d4237C0549a5057E31c8EF8D);
        usdc.transfer(buyer, 10000e6);

        // Create a loan for the user to list
        _createUserLoan();
    }

    function _createUserLoan() internal {
        vm.startPrank(user);
        votingEscrow.approve(address(loan), tokenId);
        loan.requestLoan(
            tokenId,
            100e6,
            Loan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();
    }

    function testInitAndConfig() public {
        assertEq(IMarketViewFacet(diamond).marketFeeBps(), 250);
        assertEq(IMarketViewFacet(diamond).feeRecipient(), owner);
        assertTrue(IMarketViewFacet(diamond).allowedPaymentToken(address(usdc)));
    }

    function test_makeListing_Success() public {
        // Act
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        // Assert
        (address owner_, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt) =
            IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(owner_, user);
        assertEq(price, LISTING_PRICE);
        assertEq(paymentToken, address(usdc));
        assertTrue(hasOutstandingLoan);
        assertEq(expiresAt, 0);
    }

    function test_updateListing_Success() public {
        // Arrange
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        uint256 newPrice = 2000e6;
        address newPaymentToken = address(weth);
        uint256 newExpiresAt = block.timestamp + 7 days;

        vm.prank(owner);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(newPaymentToken, true);

        // Act
        vm.prank(user);
        IMarketOperationsFacet(diamond).updateListing(tokenId, newPrice, newPaymentToken, newExpiresAt);

        // Assert
        (, uint256 price, address paymentToken, , uint256 expiresAt) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(price, newPrice);
        assertEq(paymentToken, newPaymentToken);
        assertEq(expiresAt, newExpiresAt);
    }

    function test_cancelListing_Success() public {
        // Arrange
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        // Act
        vm.prank(user);
        IMarketOperationsFacet(diamond).cancelListing(tokenId);

        // Assert
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
    }

    function test_takeListing_Success_WithOutstandingLoan() public {
        // Arrange: listing exists
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        // Get total cost and approve
        (uint256 totalCost, uint256 listingPrice, uint256 loanBalance, ) = IMarketViewFacet(diamond).getTotalCost(tokenId);
        vm.startPrank(buyer);
        usdc.approve(diamond, totalCost);

        uint16 feeBps = IMarketViewFacet(diamond).marketFeeBps();
        uint256 expectedFee = (listingPrice * feeBps) / 10000;
        uint256 buyerInitial = usdc.balanceOf(buyer);
        uint256 sellerInitial = usdc.balanceOf(user);

        // Act
        IMarketOperationsFacet(diamond).takeListing(tokenId);
        vm.stopPrank();

        // Assert: ownership and balances
        (, address newBorrower) = loan.getLoanDetails(tokenId);
        assertEq(newBorrower, buyer);

        assertEq(usdc.balanceOf(buyer), buyerInitial - totalCost);
        assertEq(usdc.balanceOf(user), sellerInitial + listingPrice - expectedFee);
        // Loan payoff was covered by totalCost; observable via reduced totalCost vs listingPrice
        assertTrue(loanBalance > 0);

        // Listing removed
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
    }

    function test_RevertWhen_MakeListing_Unauthorized() public {
        // Act + Assert
        vm.startPrank(buyer); // not owner/borrower
        vm.expectRevert();
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_TakeListing_Nonexistent() public {
        vm.startPrank(buyer);
        usdc.approve(diamond, LISTING_PRICE);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).takeListing(999999);
        vm.stopPrank();
    }

    function test_updateListing_RevertWhen_InvalidPaymentToken() public {
        // Arrange
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        // Act + Assert
        vm.prank(user);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).updateListing(tokenId, LISTING_PRICE, address(0x123), 0);
    }

    function test_createOffer_Success() public {
        uint256 minWeight = 1000;
        uint256 maxWeight = 5000;
        uint256 debtTolerance = 200e6;
        uint256 offerPrice = 2000e6;
        uint256 maxLockTime = block.timestamp + 365 days;
        uint256 expiresAt = block.timestamp + 7 days;

        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, offerPrice);
        IMarketOperationsFacet(diamond).createOffer(minWeight, maxWeight, debtTolerance, offerPrice, address(usdc), maxLockTime, expiresAt);
        vm.stopPrank();

        (address creator, uint256 oMin, uint256 oMax, uint256 oDebt, uint256 price, address paymentToken, uint256 oMaxLock, uint256 oExp)
            = IMarketViewFacet(diamond).getOffer(1);
        assertEq(creator, buyer);
        assertEq(oMin, minWeight);
        assertEq(oMax, maxWeight);
        assertEq(oDebt, debtTolerance);
        assertEq(price, offerPrice);
        assertEq(paymentToken, address(usdc));
        assertEq(oMaxLock, maxLockTime);
        assertEq(oExp, expiresAt);
        assertTrue(IMarketViewFacet(diamond).isOfferActive(1));
    }

    function test_updateOffer_Success() public {
        // Create offer
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        IMarketOperationsFacet(diamond).createOffer(1000, 5000, 200e6, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);

        // Update it
        IERC20(address(usdc)).approve(diamond, 500e6);
        IMarketOperationsFacet(diamond).updateOffer(1, 1500, 6000, 300e6, 2500e6, address(usdc), block.timestamp + 730 days, block.timestamp + 14 days);
        vm.stopPrank();

        (, uint256 minW, uint256 maxW, uint256 debtTol, uint256 price, , uint256 maxLock, uint256 exp) = IMarketViewFacet(diamond).getOffer(1);
        assertEq(minW, 1500);
        assertEq(maxW, 6000);
        assertEq(debtTol, 300e6);
        assertEq(price, 2500e6);
        assertEq(maxLock, block.timestamp + 730 days);
        assertEq(exp, block.timestamp + 14 days);
    }

    function test_cancelOffer_Success() public {
        // Create offer
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        IMarketOperationsFacet(diamond).createOffer(1000, 5000, 200e6, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);

        uint256 initial = usdc.balanceOf(buyer);
        IMarketOperationsFacet(diamond).cancelOffer(1);
        vm.stopPrank();

        (address creator,,,,,,,) = IMarketViewFacet(diamond).getOffer(1);
        assertEq(creator, address(0));
        assertEq(usdc.balanceOf(buyer), initial + 2000e6);
    }

    function test_acceptOffer_Success_FromLoanV2() public {
        // Create an offer that matches tokenId's weight range
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        IMarketOperationsFacet(diamond).createOffer(MIN_WEIGHT, MAX_WEIGHT, DEBT_TOLERANCE, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();

        // Seller accepts offer (veNFT is in LoanV2)
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).acceptOffer(tokenId, 1, true);
        vm.stopPrank();

        // Verify borrower is buyer
        (, address newBorrower) = loan.getLoanDetails(tokenId);
        assertEq(newBorrower, buyer);

        // Offer deleted
        (address creator,,,,,,,) = IMarketViewFacet(diamond).getOffer(1);
        assertEq(creator, address(0));
    }

    function test_acceptOffer_Success_FromWallet() public {
        // Find a token not in loan custody
        uint256 walletTokenId = 400;
        address walletOwner = votingEscrow.ownerOf(walletTokenId);
        vm.assume(walletOwner != address(0));
        (, address borrower) = loan.getLoanDetails(walletTokenId);
        vm.assume(borrower == address(0));

        // Create an offer with weight range close to 74.6e21 observed in UUPS tests
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        IMarketOperationsFacet(diamond).createOffer(70e21, 80e21, DEBT_TOLERANCE, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();

        // Accept offer from walletOwner
        vm.startPrank(walletOwner);
        votingEscrow.approve(diamond, walletTokenId);
        IMarketOperationsFacet(diamond).acceptOffer(walletTokenId, 1, false);
        vm.stopPrank();

        // Assert new owner is buyer (direct transfer path)
        address newOwner = votingEscrow.ownerOf(walletTokenId);
        assertEq(newOwner, buyer);
    }

    function test_matchOfferWithListing_Success() public {
        // Create a listing
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        // Create an offer matching tokenId's weight
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        IMarketOperationsFacet(diamond).createOffer(90e21, 100e21, DEBT_TOLERANCE, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();

        // Match
        IMarketOperationsFacet(diamond).matchOfferWithListing(1, tokenId);

        // Ownership moved to buyer
        (, address newBorrower) = loan.getLoanDetails(tokenId);
        assertEq(newBorrower, buyer);

        // Cleaned up
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
        (address creator,,,,,,,) = IMarketViewFacet(diamond).getOffer(1);
        assertEq(creator, address(0));
    }

    function test_RevertWhen_AcceptOffer_Expired() public {
        // Create expiring offer
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        IMarketOperationsFacet(diamond).createOffer(1000, 5000, 200e6, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 1 hours);
        vm.stopPrank();

        // Warp past expiration
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(user);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).acceptOffer(tokenId, 1, true);
        vm.stopPrank();
    }

    function test_isListingActive_RespectsExpiration() public {
        uint256 expirationTime = block.timestamp + 1 hours;
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), expirationTime);
        vm.stopPrank();

        assertTrue(IMarketViewFacet(diamond).isListingActive(tokenId));
        vm.warp(expirationTime + 1);
        assertFalse(IMarketViewFacet(diamond).isListingActive(tokenId));
    }

    function test_pause_Unpause_BlocksAndAllowsOperations() public {
        // Pause
        IMarketConfigFacet(diamond).pause();
        // Listing should revert due to paused
        vm.startPrank(user);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        // Unpause and try again
        IMarketConfigFacet(diamond).unpause();
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        (address owner_,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(owner_, user);
    }

    function test_setMarketFee_Success_And_RevertWhen_Invalid() public {
        // Success at boundary
        IMarketConfigFacet(diamond).setMarketFee(1000);
        assertEq(IMarketViewFacet(diamond).marketFeeBps(), 1000);
        // Revert > MAX
        vm.expectRevert();
        IMarketConfigFacet(diamond).setMarketFee(1001);
    }

    function test_setFeeRecipient_Success_And_RevertWhen_Zero() public {
        address newRecipient = vm.addr(0x777);
        IMarketConfigFacet(diamond).setFeeRecipient(newRecipient);
        assertEq(IMarketViewFacet(diamond).feeRecipient(), newRecipient);
        vm.expectRevert();
        IMarketConfigFacet(diamond).setFeeRecipient(address(0));
    }

    function test_setAllowedPaymentToken_Success_And_Disallow() public {
        // Disallow USDC and ensure new listings revert
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), false);
        vm.startPrank(user);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();
        // Re-allow for subsequent tests
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), true);
    }

    function test_initMarket_RevertWhen_CalledTwice() public {
        vm.expectRevert();
        IMarketConfigFacet(diamond).initMarket(address(loan), address(votingEscrow), 250, owner, address(usdc));
    }

    function test_setAllowedPaymentToken_RevertWhen_ZeroAddress() public {
        vm.expectRevert();
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(0), true);
    }

    function test_setMarketFee_RevertWhen_NotOwnerOrAdmin() public {
        vm.prank(buyer);
        vm.expectRevert();
        IMarketConfigFacet(diamond).setMarketFee(100);
    }

    function test_operatorApproval_AllowsUpdateAndCancel() public {
        // Owner creates listing
        vm.startPrank(user);
        IMarketOperationsFacet(diamond).makeListing(tokenId, LISTING_PRICE, address(usdc), 0);
        // Grant operator approval
        address operator = vm.addr(0xB0B);
        IMarketOperationsFacet(diamond).setOperatorApproval(operator, true);
        vm.stopPrank();

        // Operator updates then cancels
        uint256 newPrice = 1500e6;
        vm.prank(operator);
        IMarketOperationsFacet(diamond).updateListing(tokenId, newPrice, address(usdc), 0);
        (
            , uint256 price,,,
        ) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(price, newPrice);

        vm.prank(operator);
        IMarketOperationsFacet(diamond).cancelListing(tokenId);
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
    }

    function test_takeListing_Success_NoOutstandingLoan() public {
        // Use another token without a loan
        uint256 newTokenId = 350;
        address newOwner = votingEscrow.ownerOf(newTokenId);
        vm.assume(newOwner != address(0));

        // Move custody into LoanV2 with zero amount
        vm.startPrank(newOwner);
        votingEscrow.approve(address(loan), newTokenId);
        loan.requestLoan(newTokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        // Create listing with no loan
        IMarketOperationsFacet(diamond).makeListing(newTokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        // Total cost equals listing price (no loan)
        (uint256 totalCost, uint256 listingPrice, uint256 loanBalance,) = IMarketViewFacet(diamond).getTotalCost(newTokenId);
        assertEq(totalCost, LISTING_PRICE);
        assertEq(listingPrice, LISTING_PRICE);
        assertEq(loanBalance, 0);

        // Buyer takes listing
        vm.startPrank(buyer);
        usdc.approve(diamond, LISTING_PRICE);
        IMarketOperationsFacet(diamond).takeListing(newTokenId);
        vm.stopPrank();

        (, address newBorrower) = loan.getLoanDetails(newTokenId);
        assertEq(newBorrower, buyer);
    }

    function test_RevertWhen_MakeListing_VeNFTNotInLoanCustody() public {
        // Choose a token not in loan custody
        uint256 walletTokenId = 400;
        address walletOwner = votingEscrow.ownerOf(walletTokenId);
        vm.assume(walletOwner != address(0));
        (, address borrower) = loan.getLoanDetails(walletTokenId);
        vm.assume(borrower == address(0));

        vm.startPrank(walletOwner);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).makeListing(walletTokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_AcceptOffer_WrongFlag() public {
        // Create offer
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        IMarketOperationsFacet(diamond).createOffer(MIN_WEIGHT, MAX_WEIGHT, DEBT_TOLERANCE, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert();
        // veNFT is in LoanV2, passing false should revert
        IMarketOperationsFacet(diamond).acceptOffer(tokenId, 1, false);
        vm.stopPrank();
    }

    function test_RevertWhen_AcceptOffer_InsufficientWeight() public {
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        // Unrealistically high min weight
        IMarketOperationsFacet(diamond).createOffer(200e21, 300e21, DEBT_TOLERANCE, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).acceptOffer(tokenId, 1, true);
        vm.stopPrank();
    }

    function test_RevertWhen_AcceptOffer_ExcessiveDebt() public {
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        // Very low debt tolerance
        IMarketOperationsFacet(diamond).createOffer(MIN_WEIGHT, MAX_WEIGHT, 10e6, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).acceptOffer(tokenId, 1, true);
        vm.stopPrank();
    }

    function test_RevertWhen_UpdateOffer_Nonexistent() public {
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).updateOffer(999, 1000, 5000, 200e6, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function test_RevertWhen_CancelOffer_Nonexistent() public {
        vm.startPrank(buyer);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).cancelOffer(999);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateOffer_InvalidWeightRange() public {
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).createOffer(5000, 1000, 200e6, 2000e6, address(usdc), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateOffer_InvalidPaymentToken() public {
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, 2000e6);
        vm.expectRevert();
        IMarketOperationsFacet(diamond).createOffer(1000, 5000, 200e6, 2000e6, address(0x123), block.timestamp + 365 days, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function test_UnauthorizedMarketCannotTransferOwnership() public {
        // Use a random EOA as unauthorized market
        address unauthorizedMarket = vm.addr(0xABC);
        vm.startPrank(unauthorizedMarket);
        vm.expectRevert();
        loan.setBorrower(tokenId, buyer);
        vm.stopPrank();
    }

    function test_OwnerCanApproveAndRevokeMarketContracts() public {
        address newMarket = vm.addr(0x789);
        vm.startPrank(owner);
        loan.setApprovedContract(newMarket, true);
        assertTrue(loan.isApprovedContract(newMarket));
        loan.setApprovedContract(newMarket, false);
        assertFalse(loan.isApprovedContract(newMarket));
        vm.stopPrank();
    }
}

