// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {IMarketConfigFacet} from "../../interfaces/IMarketConfigFacet.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {AccessRoleLib} from "../../libraries/AccessRoleLib.sol";
import "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import "../../libraries/Errors.sol";

/**
 * @title MarketConfigFacet
 * @dev Facet for managing market configuration
 */
contract MarketConfigFacet is IMarketConfigFacet {
    // ============ CONSTANTS ==========
    uint16 private constant MAX_FEE_BPS = 1000; // 10%

    // ============ MODIFIERS ==========
    modifier onlyOwner() {
        if (msg.sender != LibDiamond.contractOwner()) revert Errors.NotAuthorized();
        _;
    }

    modifier onlyOwnerOrSystemAdmin() {
        address accessManager = MarketStorage.configLayout().accessManager;
        if (msg.sender == LibDiamond.contractOwner()) {
            _;
            return;
        }
        if (accessManager != address(0)) {
            (bool hasRole,) = IAccessManager(accessManager).hasRole(AccessRoleLib.MARKET_ADMIN, msg.sender);
            if (hasRole) {
                _;
                return;
            }
        }
        revert Errors.NotAuthorized();
    }

    // ============ INITIALIZER ==========
    // One-time initializer; owner-only. Mimics constructor+initialize of UUPS Market
    function initMarket(
        address loan,
        address votingEscrow,
        uint16 marketFeeBps,
        address feeRecipient,
        address defaultPaymentToken
    ) external onlyOwner {
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        require(cfg.loan == address(0) && cfg.votingEscrow == address(0), Errors.AlreadyInitialized());
        require(votingEscrow != address(0), Errors.ZeroAddress());
        require(marketFeeBps <= MAX_FEE_BPS, Errors.InvalidFee());

        cfg.loan = loan;
        cfg.votingEscrow = votingEscrow;
        cfg.feeBps[RouteLib.BuyRoute.InternalWallet] = marketFeeBps;
        cfg.feeBps[RouteLib.BuyRoute.InternalLoan] = marketFeeBps;
        cfg.feeBps[RouteLib.BuyRoute.ExternalAdapter] = marketFeeBps;
        cfg.feeRecipient = feeRecipient == address(0) ? LibDiamond.contractOwner() : feeRecipient;

        cfg.lboLenderFeeBps = 100;
        cfg.lboProtocolFeeBps = 100;

        if (defaultPaymentToken != address(0)) {
            MarketStorage.configLayout().allowedPaymentToken[defaultPaymentToken] = true;
            emit PaymentTokenAllowed(defaultPaymentToken, true);
            // If a loan is configured, default the loanAsset to the default payment token
            if (loan != address(0)) {
                cfg.loanAsset = defaultPaymentToken;
                emit LoanAssetSet(defaultPaymentToken);
            }
        }

        // Init reentrancy status and unpause
        MarketStorage.MarketPauseLayout storage pauseLayout = MarketStorage.managerPauseLayout();
        if (pauseLayout.reentrancyStatus == 0) pauseLayout.reentrancyStatus = 1; // NOT_ENTERED
        pauseLayout.marketPaused = false;

        emit MarketInitialized(loan, votingEscrow, marketFeeBps, cfg.feeRecipient, defaultPaymentToken);
    }

    // ============ ADMIN ==========
    function setMarketFee(RouteLib.BuyRoute routeType, uint16 bps) external onlyOwnerOrSystemAdmin {
        require(bps <= MAX_FEE_BPS, Errors.InvalidFee());
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        cfg.feeBps[routeType] = bps;
        emit MarketFeeChanged(bps);
    }

    function setFeeRecipient(address recipient) external onlyOwnerOrSystemAdmin {
        require(recipient != address(0), Errors.ZeroAddress());
        MarketStorage.configLayout().feeRecipient = recipient;
        emit FeeRecipientChanged(recipient);
    }

    function setAllowedPaymentToken(address token, bool allowed) external onlyOwnerOrSystemAdmin {
        require(token != address(0), Errors.ZeroAddress());
        MarketStorage.configLayout().allowedPaymentToken[token] = allowed;
        emit PaymentTokenAllowed(token, allowed);
    }

    function pause() external onlyOwnerOrSystemAdmin {
        MarketStorage.managerPauseLayout().marketPaused = true;
        emit MarketPauseStatusChanged(true);
    }

    function unpause() external onlyOwnerOrSystemAdmin {
        MarketStorage.managerPauseLayout().marketPaused = false;
        emit MarketPauseStatusChanged(false);
    }

    // AccessManager setup
    function initAccessManager(address _accessManager) external onlyOwner {
        if (_accessManager == address(0)) revert Errors.ZeroAddress();
        if (MarketStorage.configLayout().accessManager != address(0)) revert Errors.AlreadyInitialized();
        MarketStorage.configLayout().accessManager = _accessManager;
    }

    function setAccessManager(address accessManager) external onlyOwnerOrSystemAdmin {
        if (accessManager == address(0)) revert Errors.ZeroAddress();
        MarketStorage.configLayout().accessManager = accessManager;
    }

    // ============ LOAN ASSET CONFIG ==========
    function setLoanAsset(address asset) external onlyOwnerOrSystemAdmin {
        if (asset == address(0)) revert Errors.ZeroAddress();
        MarketStorage.configLayout().loanAsset = asset;
        emit LoanAssetSet(asset);
    }

    function loanAsset() external view returns (address) {
        return MarketStorage.configLayout().loanAsset;
    }

    // ============ PERMIT2 CONFIG ==========
    event Permit2Set(address permit2);

    function setPermit2(address permit2) external onlyOwnerOrSystemAdmin {
        MarketStorage.configLayout().permit2 = permit2;
        emit Permit2Set(permit2);
    }

    // ============ LBO FEE CONFIG ==========
    function setLBOLenderFeeBps(uint256 bps) external onlyOwnerOrSystemAdmin {
        require(bps <= MAX_FEE_BPS, Errors.InvalidFee());
        MarketStorage.configLayout().lboLenderFeeBps = bps;
        emit LBOLenderFeeChanged(bps);
    }

    function setLBOProtocolFeeBps(uint256 bps) external onlyOwnerOrSystemAdmin {
        require(bps <= MAX_FEE_BPS, Errors.InvalidFee());
        MarketStorage.configLayout().lboProtocolFeeBps = bps;
        emit LBOProtocolFeeChanged(bps);
    }

    // ============ EXTERNAL ADAPTER REGISTRY ==========
    function setExternalAdapter(bytes32 key, address facet) external onlyOwnerOrSystemAdmin {
        require(key != bytes32(0), Errors.InvalidAdapterKey());
        require(facet != address(0), Errors.ZeroAddress());
        MarketStorage.configLayout().externalAdapter[key] = facet;
        emit ExternalAdapterSet(key, facet);
    }
}
