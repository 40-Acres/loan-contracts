// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";

/**
 * @title AerodromeMarketplaceConfigRegression
 * @dev Verifies MarketplaceFacet and PortfolioMarketplace config wiring.
 *      Extracted from fork/AerodromeMarketplaceRegression — these tests only
 *      read constructor args and admin-set config, no on-chain interaction needed.
 */
contract AerodromeMarketplaceConfigRegression is BaseDeploymentSetup {
    address public feeRecipient = address(0x5678);
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();

        // Configure marketplace (admin operations, no fork needed)
        vm.startPrank(DEPLOYER);
        portfolioMarketplace.setProtocolFee(PROTOCOL_FEE_BPS);
        portfolioMarketplace.setFeeRecipient(feeRecipient);
        portfolioMarketplace.setAllowedPaymentToken(USDC, true);
        vm.stopPrank();
    }

    // ─── MarketplaceFacet config wiring ─────────────────────────────

    function testMarketplaceFacetPortfolioFactory() public view {
        assertEq(address(marketplaceFacet._portfolioFactory()), address(portfolioFactory));
    }

    function testMarketplaceFacetPortfolioAccountConfig() public view {
        assertEq(address(marketplaceFacet._portfolioAccountConfig()), address(portfolioAccountConfig));
    }

    function testMarketplaceFacetVotingEscrow() public view {
        assertEq(address(marketplaceFacet._votingEscrow()), VOTING_ESCROW);
    }

    function testMarketplaceFacetMarketplaceAddress() public view {
        assertEq(marketplaceFacet._marketplace(), address(portfolioMarketplace));
    }

    // ─── PortfolioMarketplace config ────────────────────────────────

    function testPortfolioMarketplaceOwner() public view {
        assertEq(portfolioMarketplace.owner(), DEPLOYER);
    }

    function testPortfolioMarketplacePortfolioManager() public view {
        assertEq(address(portfolioMarketplace.portfolioManager()), address(portfolioManager));
    }

    function testPortfolioMarketplaceVotingEscrow() public view {
        assertEq(address(portfolioMarketplace.votingEscrow()), VOTING_ESCROW);
    }

    function testPortfolioMarketplaceProtocolFee() public view {
        assertEq(portfolioMarketplace.protocolFeeBps(), PROTOCOL_FEE_BPS);
    }

    function testPortfolioMarketplaceFeeRecipient() public view {
        assertEq(portfolioMarketplace.feeRecipient(), feeRecipient);
    }

    function testPortfolioMarketplaceAllowedPaymentToken() public view {
        assertTrue(portfolioMarketplace.allowedPaymentTokens(USDC), "USDC should be allowed payment token");
    }

    // ─── Marketplace facet accessible via diamond proxy ─────────────

    function testMarketplaceViewableViaProxy() public view {
        address mktplace = IMarketplaceFacet(portfolioAccount).marketplace();
        assertEq(mktplace, address(portfolioMarketplace), "marketplace() should route through diamond proxy");
    }
}
