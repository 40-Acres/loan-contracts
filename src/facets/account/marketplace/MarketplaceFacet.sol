// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";
import {IMarketViewFacet} from "../../../interfaces/IMarketViewFacet.sol";
import {IMarketRouterFacet} from "../../../interfaces/IMarketRouterFacet.sol";
import {IFlashLoanProvider} from "../../../interfaces/IFlashLoanProvider.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RouteLib} from "../../../libraries/RouteLib.sol";

/**
 * @title MarketplaceFacet
 * @dev Diamond facet for marketplace operations on portfolio accounts
 * Handles marketplace purchases and offers for veNFTs held by portfolios
 * 
 * This facet is called by the market diamond to finalize purchases,
 * transfers, and update collateral tracking when veNFTs change hands.
 */
contract MarketplaceFacet {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error NotAuthorized();
    error ZeroAddress();
    error InvalidListing();
    error InvalidOffer();
    error LoanNotPaidOff();
    error Unauthorized();
    error NotPortfolioOwner();
    error VeNFTNotInPortfolio();
    error InvalidFlashLoanCaller();
    error LBOFailed();
    error InsufficientFunds();

    // ============ Events ============
    event VeNFTSold(uint256 indexed tokenId, address indexed seller, address indexed buyer);
    event CollateralRemoved(uint256 indexed tokenId);
    event LBOExecuted(uint256 indexed tokenId, address indexed buyer, uint256 loanAmount);
    event CollateralAdded(uint256 indexed tokenId, uint256 debtAmount);
    event LBOProtocolFeePaid(uint256 indexed tokenId, address indexed buyer, uint256 feeAmount, address feeRecipient);

    // ============ Immutables ============
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public immutable _ve;
    address public immutable _loanContract;
    address public immutable _marketDiamond;

    constructor(
        address portfolioFactory,
        address accountConfigStorage,
        address ve,
        address loanContract,
        address marketDiamond
    ) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        require(ve != address(0));
        require(loanContract != address(0));
        require(marketDiamond != address(0));
        
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _ve = IVotingEscrow(ve);
        _loanContract = loanContract;
        _marketDiamond = marketDiamond;
    }

    // ============ Modifiers ============

    modifier onlyMarketDiamond() {
        if (msg.sender != _marketDiamond) revert NotAuthorized();
        _;
    }

    modifier onlyPortfolioOwner() {
        if (msg.sender != _portfolioFactory.ownerOf(address(this))) revert NotPortfolioOwner();
        _;
    }

    // ============ External Functions ============

    /**
     * @notice Finalizes a marketplace direct listing purchase
     * @dev Called by the market diamond after payment is processed
     *      Transfers the veNFT from this portfolio to the buyer
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer (can be EOA or portfolio)
     * @param expectedSeller The expected seller address for validation
     */
    function finalizeMarketPurchase(
        uint256 tokenId,
        address buyer,
        address expectedSeller
    ) external onlyMarketDiamond {
        if (buyer == address(0)) revert ZeroAddress();
        
        // Verify this portfolio is the seller
        if (address(this) != expectedSeller) revert InvalidListing();

        // Verify listing is valid via MarketView facet on the diamond caller
        (address listingOwner, , , , uint256 expiresAt) = IMarketViewFacet(msg.sender).getListing(tokenId);
        if (listingOwner == address(0)) revert InvalidListing();
        if (expiresAt != 0 && block.timestamp >= expiresAt) revert InvalidListing();
        if (listingOwner != address(this)) revert InvalidListing();

        // Verify this portfolio owns the veNFT
        if (_ve.ownerOf(tokenId) != address(this)) revert VeNFTNotInPortfolio();

        // Check loan balance is zero (loan should be paid off before transfer)
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance != 0) revert LoanNotPaidOff();

        // Remove collateral tracking from this portfolio
        CollateralManager.removeLockedColleratal(tokenId, address(_accountConfigStorage));
        
        // Transfer veNFT to buyer
        _ve.transferFrom(address(this), buyer, tokenId);

        emit VeNFTSold(tokenId, address(this), buyer);
        emit CollateralRemoved(tokenId);
    }

    /**
     * @notice Finalizes an offer acceptance
     * @dev Called by the market diamond after payment is processed
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer
     * @param expectedSeller The expected seller address for validation
     * @param offerId The ID of the offer being accepted
     */
    function finalizeOfferPurchase(
        uint256 tokenId,
        address buyer,
        address expectedSeller,
        uint256 offerId
    ) external onlyMarketDiamond {
        if (buyer == address(0)) revert ZeroAddress();
        
        // Verify this portfolio is the seller
        if (address(this) != expectedSeller) revert InvalidOffer();

        // Validate the offer is present and active
        (
            address creator,
            ,
            ,
            ,
            ,
            uint256 expiresAt
        ) = IMarketViewFacet(msg.sender).getOffer(offerId);
        if (creator == address(0)) revert InvalidOffer();
        if (creator != buyer) revert InvalidOffer();
        if (expiresAt != 0 && block.timestamp >= expiresAt) revert InvalidOffer();

        // Verify this portfolio owns the veNFT
        if (_ve.ownerOf(tokenId) != address(this)) revert VeNFTNotInPortfolio();

        // Check loan balance is zero
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance != 0) revert LoanNotPaidOff();

        // Remove collateral tracking from this portfolio
        CollateralManager.removeLockedColleratal(tokenId, address(_accountConfigStorage));
        
        // Transfer veNFT to buyer
        _ve.transferFrom(address(this), buyer, tokenId);

        emit VeNFTSold(tokenId, address(this), buyer);
        emit CollateralRemoved(tokenId);
    }

    /**
     * @notice Finalizes a Leveraged Buyout (LBO) purchase
     * @dev Called by the market diamond after flash loan is used to purchase
     *      In LBO, the market diamond temporarily becomes the borrower, then transfers to buyer
     * @param tokenId The ID of the veNFT being purchased via LBO
     * @param buyer The final buyer address
     */
    function finalizeLBOPurchase(
        uint256 tokenId,
        address buyer
    ) external onlyMarketDiamond {
        if (buyer == address(0)) revert ZeroAddress();
        
        // In LBO flow, the market diamond should be the current holder
        // This function is called to transfer from market diamond to buyer's portfolio
        // The veNFT should already be with the market diamond at this point
        
        // Verify this portfolio is meant to receive the NFT (buyer should be portfolio owner)
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        if (portfolioOwner != buyer) revert Unauthorized();

        // Transfer veNFT from market diamond to this portfolio
        _ve.transferFrom(msg.sender, address(this), tokenId);
        
        // Add collateral tracking to this portfolio
        CollateralManager.addLockedColleratal(tokenId, address(_ve));

        // Get the loan balance and add to debt tracking
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance > 0) {
            CollateralManager.increaseTotalDebt(address(_accountConfigStorage), balance);
        }

        emit VeNFTSold(tokenId, msg.sender, address(this));
    }

    /**
     * @notice Receive a veNFT into this portfolio from a marketplace purchase
     * @dev Called after buying a veNFT to add it to collateral tracking
     * @param tokenId The ID of the veNFT received
     */
    function receiveMarketPurchase(uint256 tokenId) external onlyMarketDiamond {
        // Verify this portfolio now owns the veNFT
        if (_ve.ownerOf(tokenId) != address(this)) revert VeNFTNotInPortfolio();
        
        // Add collateral tracking
        CollateralManager.addLockedColleratal(tokenId, address(_ve));

        // Check if there's associated debt
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance > 0) {
            CollateralManager.increaseTotalDebt(address(_accountConfigStorage), balance);
        }
    }

    // ============ LBO Functions ============

    /**
     * @notice Execute a Leveraged Buyout to purchase a veNFT using flash loan
     * @dev Portfolio owner calls this to buy a veNFT with leverage
     * @param tokenId The veNFT to purchase
     * @param route Purchase route (InternalWallet, InternalLoan, ExternalAdapter)
     * @param adapterKey Adapter key for external routes
     * @param inputAsset Asset for purchase (address(0) for ETH)
     * @param maxPaymentTotal Max total payment in purchase asset
     * @param userPaymentAsset Asset provided by user (can differ from inputAsset if swap needed)
     * @param userPaymentAmount Amount user is contributing
     * @param purchaseTradeData ODOS data for purchase swap (if inputAsset != listing currency)
     * @param lboTradeData ODOS data for LBO swap (user asset + flash loan -> purchase asset)
     * @param marketData Adapter-specific data
     */
    function executeLBO(
        uint256 tokenId,
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        address inputAsset,
        uint256 maxPaymentTotal,
        address userPaymentAsset,
        uint256 userPaymentAmount,
        bytes calldata purchaseTradeData,
        bytes calldata lboTradeData,
        bytes calldata marketData
    ) external payable onlyPortfolioOwner {
        // Collect user payment
        if (userPaymentAsset == address(0)) {
            // ETH payment
            if (msg.value != userPaymentAmount) revert InsufficientFunds();
        } else if (userPaymentAmount > 0) {
            // ERC20 payment - pull from user
            IERC20(userPaymentAsset).safeTransferFrom(msg.sender, address(this), userPaymentAmount);
        }

        // Get max loan amount for this token
        (uint256 maxLoan,) = ILoan(_loanContract).getMaxLoan(tokenId);
        
        // Encode callback data
        bytes memory callbackData = abi.encode(
            tokenId,
            route,
            adapterKey,
            inputAsset,
            maxPaymentTotal,
            userPaymentAsset,
            userPaymentAmount,
            maxLoan,
            purchaseTradeData,
            lboTradeData,
            marketData
        );

        // Execute flash loan - callback will handle purchase and loan request
        IFlashLoanProvider(_loanContract).flashLoan(maxLoan, callbackData);
    }

    /**
     * @notice Flash loan callback for LBO execution
     * @dev Called by LoanV2 during flash loan - handles purchase and loan creation
     * @param initiator The portfolio owner who initiated the LBO
     * @param token The flash loaned token (USDC)
     * @param amount The flash loan amount
     * @param fee The flash loan fee (0 for internal)
     * @param data Encoded LBO parameters
     * @return success True if callback succeeded
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bool) {
        // Verify caller is the loan contract
        if (msg.sender != _loanContract) revert InvalidFlashLoanCaller();

        // Decode callback data
        (
            uint256 tokenId,
            RouteLib.BuyRoute route,
            bytes32 adapterKey,
            address inputAsset,
            uint256 maxPaymentTotal,
            address userPaymentAsset,
            uint256 userPaymentAmount,
            uint256 maxLoan,
            bytes memory purchaseTradeData,
            bytes memory lboTradeData,
            bytes memory marketData
        ) = abi.decode(data, (uint256, RouteLib.BuyRoute, bytes32, address, uint256, address, uint256, uint256, bytes, bytes, bytes));

        // Step 1: Swap user payment + flash loan to purchase asset if needed
        if (lboTradeData.length > 0) {
            _executeOdosSwap(token, amount, userPaymentAsset, userPaymentAmount, lboTradeData);
        }

        // Step 2: Approve and execute purchase via MarketDiamond
        IERC20(inputAsset).forceApprove(_marketDiamond, maxPaymentTotal);
        
        IMarketRouterFacet(_marketDiamond).buyToken(
            route,
            adapterKey,
            tokenId,
            inputAsset,
            maxPaymentTotal,
            maxPaymentTotal, // maxInputAmount
            purchaseTradeData,
            marketData,
            bytes("") // no permit2 needed, we already have funds
        );

        // Step 3: Verify we received the NFT
        if (_ve.ownerOf(tokenId) != address(this)) revert VeNFTNotInPortfolio();

        // Step 4: Calculate and pay upfront LBO protocol fee
        uint256 lboProtocolFeeBps = IMarketViewFacet(_marketDiamond).getLBOProtocolFeeBps();
        if (lboProtocolFeeBps > 0) {
            // Calculate fee based on listing price (maxPaymentTotal approximates this)
            // For external routes, back out the route fee to get base listing price
            uint256 listingPriceForFee = maxPaymentTotal;
            // if (route == RouteLib.BuyRoute.ExternalAdapter) {
            //     // External routes include their fee in maxPaymentTotal
            //     // total = price + (price * bps / 10000) => price = total * 10000 / (10000 + bps)
            //     // We approximate by using maxPaymentTotal as-is since we don't have route fee bps here
            // }
            
            uint256 upfrontLBOFee = (listingPriceForFee * lboProtocolFeeBps) / 10000;
            if (upfrontLBOFee > 0) {
                address feeRecipient = IMarketViewFacet(_marketDiamond).feeRecipient();
                IERC20(inputAsset).safeTransfer(feeRecipient, upfrontLBOFee);
                emit LBOProtocolFeePaid(tokenId, initiator, upfrontLBOFee, feeRecipient);
            }
        }

        // Step 5: Request loan against the purchased NFT
        _ve.approve(_loanContract, tokenId);
        
        ILoan(_loanContract).requestLoan(
            tokenId,
            maxLoan,
            ILoan.ZeroBalanceOption.DoNothing,
            0,              // increasePercentage
            address(0),     // preferredToken
            false,          // topUp
            false           // optInCommunityRewards
        );

        // Step 6: Track collateral and debt in CollateralManager
        CollateralManager.addLockedColleratal(tokenId, address(_ve));
        CollateralManager.increaseTotalDebt(address(_accountConfigStorage), maxLoan);

        // Step 7: Approve flash loan repayment
        IERC20(token).forceApprove(msg.sender, amount + fee);

        emit LBOExecuted(tokenId, initiator, maxLoan);
        emit CollateralAdded(tokenId, maxLoan);

        return true;
    }

    /**
     * @dev Execute ODOS swap for LBO
     */
    function _executeOdosSwap(
        address flashLoanToken,
        uint256 flashLoanAmount,
        address userPaymentAsset,
        uint256 userPaymentAmount,
        bytes memory tradeData
    ) internal {
        address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;

        // Approve flash loan token for ODOS
        IERC20(flashLoanToken).forceApprove(odos, flashLoanAmount);

        // Approve user payment asset for ODOS (if ERC20)
        uint256 ethValue = 0;
        if (userPaymentAsset == address(0)) {
            ethValue = userPaymentAmount;
        } else if (userPaymentAmount > 0) {
            IERC20(userPaymentAsset).forceApprove(odos, userPaymentAmount);
        }

        // Execute swap
        (bool success,) = odos.call{value: ethValue}(tradeData);
        if (!success) revert LBOFailed();

        // Reset approvals
        IERC20(flashLoanToken).forceApprove(odos, 0);
        if (userPaymentAsset != address(0) && userPaymentAmount > 0) {
            IERC20(userPaymentAsset).forceApprove(odos, 0);
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get the portfolio owner
     * @return The address of the portfolio owner
     */
    function getPortfolioOwner() external view returns (address) {
        return _portfolioFactory.ownerOf(address(this));
    }

    /**
     * @notice Check if this portfolio owns a specific veNFT
     * @param tokenId The token ID to check
     * @return True if this portfolio owns the veNFT
     */
    function ownsVeNFT(uint256 tokenId) external view returns (bool) {
        return _ve.ownerOf(tokenId) == address(this);
    }
}
