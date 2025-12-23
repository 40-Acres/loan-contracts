// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccessControl} from "../utils/AccessControl.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {UserMarketplaceModule} from "./UserMarketplaceModule.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {CollateralFacet} from "../collateral/CollateralFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IMarketplaceFacet} from "../../../interfaces/IMarketplaceFacet.sol";

contract MarketplaceFacet is AccessControl, IMarketplaceFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    address public immutable _marketplace;

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address marketplace) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(votingEscrow != address(0));
        require(marketplace != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _marketplace = marketplace;
    }

    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 debtAttached,
        uint256 expiresAt,
        address allowedBuyer
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(CollateralFacet(address(this)).getLockedCollateral(tokenId) > 0, "Token not locked");
        require(CollateralFacet(address(this)).getOriginTimestamp(tokenId) > 0, "Token not originated");
        UserMarketplaceModule.createListing(tokenId, price, paymentToken, debtAttached, expiresAt, allowedBuyer);
    }

    function cancelListing(uint256 tokenId) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.removeListing(tokenId);
    }

    /**
     * @notice Get listing details for a token
     * @param tokenId The token ID
     * @return listing The listing details
     */
    function getListing(uint256 tokenId) external view returns (UserMarketplaceModule.Listing memory) {
        return UserMarketplaceModule.getListing(tokenId);
    }

    /**
     * @notice Processes payment from marketplace, pays down debt if needed, and approves seller to take remaining funds
     * @dev Called by marketplace after taking funds from buyer
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer
     * @param paymentAmount The amount being paid (should match listing price)
     */
    function processPayment(
        uint256 tokenId,
        address buyer,
        uint256 paymentAmount
    ) external {
        require(msg.sender == _marketplace, "Not marketplace");
        require(buyer != address(0), "Invalid buyer");
        
        // Get listing from user marketplace module
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        
        // Validate listing exists
        require(listing.owner != address(0), "Listing does not exist");
        
        // Ensure listing hasn't expired (0 = never expires)
        require(listing.expiresAt == 0 || listing.expiresAt > block.timestamp, "Listing expired");
        
        // Validate buyer if restricted
        require(listing.allowedBuyer == address(0) || listing.allowedBuyer == buyer, "Buyer not allowed");
        
        // Validate payment amount matches listing price
        require(paymentAmount == listing.price, "Payment amount mismatch");
        
        // Verify token is owned by this portfolio account
        require(_votingEscrow.ownerOf(tokenId) == address(this), "Token not in portfolio");
        
        // Check that token has locked collateral
        require(CollateralFacet(address(this)).getLockedCollateral(tokenId) > 0, "Token not locked");
        
        // Get portfolio owner (seller)
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        
        // Transfer payment token from marketplace to this portfolio account
        IERC20 paymentToken = IERC20(listing.paymentToken);
        paymentToken.transferFrom(msg.sender, address(this), paymentAmount);
        
        // Handle debt payment if there's debt attached or current debt
        uint256 remainingAmount = paymentAmount;
        uint256 totalDebt = CollateralFacet(address(this)).getTotalDebt();
        
        // Use debtAttached if specified, otherwise use current total debt
        uint256 debtToPay = listing.debtAttached > 0 ? listing.debtAttached : totalDebt;
        
        if (debtToPay > 0 && totalDebt > 0) {
            // Cap debt payment to actual total debt
            uint256 actualDebtToPay = debtToPay > totalDebt ? totalDebt : debtToPay;
            
            // Cap debt payment to available payment amount
            if (actualDebtToPay > remainingAmount) {
                actualDebtToPay = remainingAmount;
            }
            
            if (actualDebtToPay > 0) {
                // Get loan contract
                address loanContract = _portfolioAccountConfig.getLoanContract();
                require(loanContract != address(0), "Loan contract not set");
                
                // Approve loan contract to take payment
                paymentToken.approve(loanContract, actualDebtToPay);
                
                // Pay down debt
                CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), actualDebtToPay);
                
                // Clear approval
                paymentToken.approve(loanContract, 0);
                
                remainingAmount -= actualDebtToPay;
            }
        }
        
        // Transfer remaining amount to portfolio owner (seller)
        if (remainingAmount > 0) {
            paymentToken.transfer(portfolioOwner, remainingAmount);
        }
        
        // Remove listing from user marketplace module
        UserMarketplaceModule.removeListing(tokenId);
        
        // Transfer NFT to buyer
        _votingEscrow.transferFrom(address(this), buyer, tokenId);
        
        // Remove collateral from collateral manager
        CollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
        CollateralManager.enforceCollateralRequirements();
    }
}
