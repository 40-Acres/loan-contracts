// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {IMarketConfigFacet} from "../../interfaces/IMarketConfigFacet.sol";
import {AccessRoleLib} from "../../libraries/MarketSystemRoleLib.sol";
import "@openzeppelin/contracts/access/manager/IAccessManager.sol";
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
        require(cfg.loan == address(0) && cfg.votingEscrow == address(0), "Already initialized");
        require(loan != address(0) && votingEscrow != address(0), "Zero address");
        require(marketFeeBps <= MAX_FEE_BPS, "Invalid fee");

        cfg.loan = loan;
        cfg.votingEscrow = votingEscrow;
        cfg.marketFeeBps = marketFeeBps;
        cfg.feeRecipient = feeRecipient == address(0) ? LibDiamond.contractOwner() : feeRecipient;

        if (defaultPaymentToken != address(0)) {
            MarketStorage.configLayout().allowedPaymentToken[defaultPaymentToken] = true;
            emit PaymentTokenAllowed(defaultPaymentToken, true);
        }

        // Init reentrancy status and unpause
        MarketStorage.MarketPauseLayout storage pauseLayout = MarketStorage.managerPauseLayout();
        if (pauseLayout.reentrancyStatus == 0) pauseLayout.reentrancyStatus = 1; // NOT_ENTERED
        pauseLayout.marketPaused = false;

        emit MarketInitialized(loan, votingEscrow, marketFeeBps, cfg.feeRecipient, defaultPaymentToken);
    }

    // ============ ADMIN ==========
    function setMarketFee(uint16 bps) external onlyOwnerOrSystemAdmin {
        require(bps <= MAX_FEE_BPS, "Invalid fee");
        MarketStorage.configLayout().marketFeeBps = bps;
        emit MarketFeeChanged(bps);
    }

    function setFeeRecipient(address recipient) external onlyOwnerOrSystemAdmin {
        require(recipient != address(0), "Zero address");
        MarketStorage.configLayout().feeRecipient = recipient;
        emit FeeRecipientChanged(recipient);
    }

    function setAllowedPaymentToken(address token, bool allowed) external onlyOwnerOrSystemAdmin {
        require(token != address(0), "Zero address");
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
}
