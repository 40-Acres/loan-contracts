// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {IMarketRouterFacet} from "../../interfaces/IMarketRouterFacet.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";
import {IVexyAdapterFacet} from "../../interfaces/IVexyAdapterFacet.sol";
import {RevertHelper} from "../../libraries/RevertHelper.sol";
import {Errors} from "../../libraries/Errors.sol";

import {IFlashLoanReceiver} from "../../interfaces/IFlashLoanReceiver.sol";
import {ILoan} from "../../interfaces/ILoan.sol";
import {IFlashLoanProvider} from "../../interfaces/IFlashLoanProvider.sol";
import {Permit2Lib} from "../../libraries/Permit2Lib.sol";

contract MarketRouterFacet is IMarketRouterFacet, IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    struct purchaseOrder {
        RouteLib.BuyRoute route;
        bytes32 adapterKey;
        uint256 tokenId;
        address inputAsset;
        uint256 maxPaymentTotal;
        uint256 maxInputAmount;
        bytes tradeData;
        bytes marketData;
        bytes optionalPermit2;
    }
    
    modifier onlyWhenNotPaused() {
        if (MarketStorage.managerPauseLayout().marketPaused) revert Errors.Paused();
        _;
    }

    modifier nonReentrant() {
        MarketStorage.MarketPauseLayout storage pause = MarketStorage.managerPauseLayout();
        if (pause.reentrancyStatus == 2) revert Errors.Reentrancy();
        pause.reentrancyStatus = 2;
        _;
        pause.reentrancyStatus = 1;
    }

    function quoteToken(
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        uint256 tokenId,
        bytes calldata quoteData
        ) external view returns (
            uint256 listingPriceInPaymentToken,
            uint256 protocolFeeInPaymentToken,
            address paymentToken
        ) {
        if (route == RouteLib.BuyRoute.InternalWallet) {
            (uint256 p,uint256 f,address pay) = _quoteInternalWallet(tokenId);
            return (p,f,pay);
        }
        if (route == RouteLib.BuyRoute.InternalLoan) {
            (uint256 p,uint256 f,address pay) = _quoteInternalLoan(tokenId);
            return (p,f,pay);
        }
        // External adapters quote via adapterKey/quoteData path
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        address adapter = cfg.externalAdapter[adapterKey];
        if (adapter == address(0)) revert Errors.UnknownAdapter();

        // Delegatecall into adapter to allow reading diamond storage
        (bool success, bytes memory result) =
            adapter.staticcall(abi.encodeWithSignature("quoteToken(uint256,bytes)", tokenId, quoteData));
        if (!success) {
            RevertHelper.revertWithData(result);
        }
        (uint256 price, , address currency) = abi.decode(result, (uint256, uint256, address));
        uint256 fee = (price * cfg.feeBps[RouteLib.BuyRoute.ExternalAdapter]) / 10000;
        return (price, fee, currency);
    }

    function buyToken(
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        uint256 tokenId,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata marketData,
        bytes calldata optionalPermit2
    ) external payable onlyWhenNotPaused {
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();

        // Single-veNFT per diamond: no escrow parameter; cfg.votingEscrow is authoritative
        // Guard: if a non-ETH input asset is specified, do not accept ETH value
        if (inputAsset != address(0) && msg.value > 0) revert Errors.NoETHForTokenPayment();
        // Guard: if ETH is input and no swap data provided, revert early (no direct-ETH listings supported)
        if (inputAsset == address(0) && tradeData.length == 0) revert Errors.NoTradeData();
        // Guard: disable internal loan route unless a loan implementation is configured
        if (route == RouteLib.BuyRoute.InternalLoan && cfg.loan == address(0)) revert Errors.LoanNotConfigured();

        if (route == RouteLib.BuyRoute.InternalWallet) {
            (uint256 price, uint256 fee, address paymentToken) = _quoteInternalWallet(tokenId);
            uint256 total = price; // seller pays fee; total user spend bounded by maxTotal
            if (inputAsset == paymentToken && tradeData.length == 0) {
                if (total > maxPaymentTotal) revert Errors.MaxTotalExceeded();
                IMarketListingsWalletFacet(address(this)).takeWalletListingFor{value: msg.value}(tokenId, msg.sender, inputAsset, 0, bytes(""), optionalPermit2);
            } else if (tradeData.length > 0) {
                IMarketListingsWalletFacet(address(this)).takeWalletListingFor{value: msg.value}(tokenId, msg.sender, inputAsset, maxInputAmount, tradeData, optionalPermit2);
            } else {
                revert Errors.NoTradeData();
            }

        } else if (route == RouteLib.BuyRoute.InternalLoan) {
            // Route to unified loan entry. If swap needed, we can bypass quote to support cross-asset payoff
            if (tradeData.length == 0) {
                // Get total cost of listing via quote helper (single-asset quote path)
                (uint256 total,,) = _quoteInternalLoan(tokenId);
                if (total > maxPaymentTotal) revert Errors.MaxTotalExceeded();
                if (inputAsset == address(0)) revert Errors.NoETHForTokenPayment();
                IMarketListingsLoanFacet(address(this)).takeLoanListingFor(tokenId, msg.sender, inputAsset, 0, bytes(""), optionalPermit2);
            } else {
                IMarketListingsLoanFacet(address(this)).takeLoanListingFor{value: msg.value}(tokenId, msg.sender, inputAsset, maxInputAmount, tradeData, optionalPermit2);
            }

        } else if (route == RouteLib.BuyRoute.ExternalAdapter) {
            // Look up adapter for the given key
            address adapter = cfg.externalAdapter[adapterKey];
            if (adapter == address(0)) revert Errors.UnknownAdapter();

            // Delegate call to the associated external adapter facet (uniform ABI)
            (bool success, bytes memory result) =
                adapter.delegatecall(abi.encodeWithSignature(
                    "buyToken(uint256,uint256,address,uint256,bytes,bytes,bytes)",
                    tokenId,
                    maxPaymentTotal,
                    inputAsset,
                    maxInputAmount,
                    tradeData,
                    marketData,
                    optionalPermit2
                ));
            if (!success) {
                RevertHelper.revertWithData(result);
            }
        } else {
            revert Errors.InvalidRoute();
        }
    }


    function buyTokenWithLBO(uint256 tokenId, address userPaymentAsset, uint256 userPaymentAmount, bytes calldata purchaseOrderData, bytes calldata tradeData, bytes calldata optionalPermit2) external payable onlyWhenNotPaused {
        // decode purchaseOrder
        purchaseOrder memory purchase = abi.decode(purchaseOrderData, (purchaseOrder));
        
        // Validate purchase order matches tokenId
        if (purchase.tokenId != tokenId) revert Errors.InvalidTokenId();

        // we will not have tradeData if the purchaseOrder inputAsset is the same as the userPaymentAsset, because that means we start the buyToken in the callback with the userPaymentAsset and borrowed asset in the same token and no swap is needed
        if (purchase.inputAsset != userPaymentAsset && tradeData.length == 0) revert Errors.NoTradeData();
        
        // Guard: if a non-ETH input asset is specified, do not accept ETH value
        if (userPaymentAsset != address(0) && msg.value > 0) revert Errors.NoETHForTokenPayment();
        
        // Collect user payment
        if (userPaymentAsset == address(0)) {
            // ETH payment
            if (msg.value != userPaymentAmount) revert Errors.InsufficientETH();
        } else {
            // ERC20 payment - collect from user using Permit2
            // Pull max input via Permit2 if provided; otherwise fallback
            Permit2Lib.permitAndPull(msg.sender, address(this), userPaymentAsset, userPaymentAmount, optionalPermit2);
            if (optionalPermit2.length == 0) {
                IERC20(userPaymentAsset).safeTransferFrom(msg.sender, address(this), userPaymentAmount);
            }
        }


        // Calculate LBO fees (200 bps total on listing price)
        uint256 listingPrice = purchase.maxPaymentTotal;
        uint256 upfrontProtocolFee = (listingPrice * 100) / 10000; // 100 bps paid upfront to protocol
        uint256 financedFee = (listingPrice * 100) / 10000; // 100 bps added to loan (50 bps protocol + 50 bps lenders)
        
        // Total amount needed for purchase: listing price + upfront fee
        uint256 totalNeeded = listingPrice + upfrontProtocolFee;
        
        // Flash loan the max loan amount (always in vault asset/USDC)
        // User payment + flash loan will be swapped together to cover totalNeeded
        (uint256 maxLoan, ) = ILoan(MarketStorage.configLayout().loan).getMaxLoan(tokenId);
        uint256 flashLoanAmount = maxLoan;
        
        // Prepare data for flash loan callback
        bytes memory flashLoanData = abi.encode(
            purchase,
            tradeData,
            optionalPermit2,
            msg.sender, // buyer
            userPaymentAsset,
            userPaymentAmount,
            listingPrice,
            upfrontProtocolFee, // 100 bps paid upfront to protocol
            financedFee         // 100 bps to be added to loan balance
        );
        
        // Get loan contract and vault asset (USDC)
        address loanContract = MarketStorage.configLayout().loan;
        address vaultAsset = MarketStorage.configLayout().loanAsset;
        
        // Call flash loan - this will trigger onFlashLoan callback
        IFlashLoanProvider(loanContract).flashLoan(
            IFlashLoanReceiver(address(this)),
            vaultAsset,
            flashLoanAmount,
            flashLoanData
        );
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        // Verify caller is the loan contract
        require(msg.sender == MarketStorage.configLayout().loan, "Invalid flash loan caller");
        
        // Decode the flash loan data
        (
            purchaseOrder memory purchase,
            bytes memory tradeData,
            bytes memory optionalPermit2,
            address buyer,
            address userPaymentAsset,
            uint256 userPaymentAmount,
            uint256 listingPrice,
            uint256 upfrontProtocolFee,
            uint256 financedFee
        ) = abi.decode(data, (purchaseOrder, bytes, bytes, address, address, uint256, uint256, uint256, uint256));
        
        // Handle asset swapping if needed
        if (tradeData.length > 0) {
            // Multi-asset swap path using ODOS
            address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
            
            // Approve both user payment asset and flash loan token for ODOS
            if (userPaymentAsset != address(0)) {
                IERC20(userPaymentAsset).forceApprove(odos, userPaymentAmount);
            }
            IERC20(token).forceApprove(odos, amount);
            
            // Execute the swap
            uint256 ethValue = 0;
            if (userPaymentAsset == address(0)) {
                ethValue = userPaymentAmount; // User paid in ETH
            }
            
            (bool success,) = odos.call{value: ethValue}(tradeData);
            require(success, "ODOS swap failed");
            
            // Reset approvals
            if (userPaymentAsset != address(0)) {
                IERC20(userPaymentAsset).forceApprove(odos, 0);
            }
            IERC20(token).forceApprove(odos, 0);
            
            // Verify we have enough of the target asset for the purchase
            uint256 targetBalance = IERC20(purchase.inputAsset).balanceOf(address(this));
            require(targetBalance >= purchase.maxPaymentTotal, Errors.Slippage());
        } else {
            // TODO: review this path
            // No swap needed - verify assets match and we have sufficient balance
            require(token == purchase.inputAsset, "Flash loan asset must match purchase asset");
            if (userPaymentAsset != address(0)) {
                require(userPaymentAsset == purchase.inputAsset, "User asset must match purchase asset");
            }
            uint256 totalBalance = userPaymentAmount + amount;
            require(totalBalance >= purchase.maxPaymentTotal, "Insufficient balance for purchase");
        }

        // store the listing payment token for this tokenid
        address listingPaymentToken = MarketStorage.orderbookLayout().listings[purchase.tokenId].paymentToken;
        
        // Now we should have the correct asset for the purchase
        // TODO: should we just make the takeListingFrom skip transfer if self-call?
        // Approve ourselves to spend the purchase asset for buyToken
        IERC20(purchase.inputAsset).forceApprove(address(this), purchase.maxPaymentTotal);
        
        // Call buyToken to purchase the NFT
        this.buyToken(
            purchase.route,
            purchase.adapterKey,
            purchase.tokenId,
            purchase.inputAsset,
            purchase.maxPaymentTotal,
            purchase.maxInputAmount,
            purchase.tradeData,
            purchase.marketData,
            optionalPermit2
        );
        
        // At this point, the market diamond owns the NFT
        
        // Pay upfront protocol fee (100 bps) in listing payment token to treasury
        // The remaining 100 bps (50 bps protocol + 50 bps lenders) will be added to loan balance in finalizeLBOPurchase
        
        if (upfrontProtocolFee > 0) {
            IERC20(listingPaymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, upfrontProtocolFee);
        }

        // Request max loan to get funds to repay flash loan + financed fee (100 bps)
        address loanContract = MarketStorage.configLayout().loan;
        address votingEscrow = MarketStorage.configLayout().votingEscrow;
        
        // Approve the loan contract to transfer the NFT
        IERC721(votingEscrow).approve(loanContract, purchase.tokenId);
        
        ILoan(loanContract).requestLoan(
            purchase.tokenId,
            0, // Let it calculate max loan
            ILoan.ZeroBalanceOption.DoNothing, // Default option
            0, // No increase percentage
            address(0), // No preferred token
            true, // topUp = true (get max loan)
            false // No community rewards
        );

        // the loan contract now holds the nft and this market diamond is the borrower / owner of that nft in custody of loan contract
        
        // Approve flash loan repayment (amount + fee = amount + 0)
        IERC20(token).forceApprove(msg.sender, amount + fee);
        
        // Transfer borrower ownership to the buyer and add financed fee to loan balance
        ILoan(loanContract).finalizeLBOPurchase(purchase.tokenId, buyer);
        
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    // internal functions for internal routes
    function _quoteInternalWallet(uint256 tokenId) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    ) {
        return IMarketListingsWalletFacet(address(this)).quoteWalletListing(tokenId);
    }

    function _quoteInternalLoan(uint256 tokenId) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    ) {
        (uint256 a,uint256 b,,address d) = IMarketListingsLoanFacet(address(this)).quoteLoanListing(tokenId, address(0));
        return (a,b,d);
    }
    
}


