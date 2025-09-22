// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
import {RouteLib} from "../libraries/RouteLib.sol";

interface IMarketConfigFacet {
    // Events
    event PaymentTokenAllowed(address indexed token, bool allowed);
    event MarketFeeChanged(uint16 newBps);
    event FeeRecipientChanged(address newRecipient);
    event MarketInitialized(address loan, address votingEscrow, uint16 marketFeeBps, address feeRecipient, address defaultPaymentToken);
    event MarketPauseStatusChanged(bool isPaused);
    event LoanAssetSet(address asset);
    event ExternalAdapterSet(bytes32 key, address facet);
    event LBOLenderFeeChanged(uint256 newBps);
    event LBOProtocolFeeChanged(uint256 newBps);

    // Initializer
    function initMarket(
        address loan,
        address votingEscrow,
        uint16 marketFeeBps,
        address feeRecipient,
        address defaultPaymentToken
    ) external;

    // Admin
    function setMarketFee(RouteLib.BuyRoute routeType, uint16 bps) external;
    function setFeeRecipient(address recipient) external;
    function setAllowedPaymentToken(address token, bool allowed) external;
    function pause() external;
    function unpause() external;

    // AccessManager
    function initAccessManager(address _accessManager) external;
    function setAccessManager(address accessManager) external;

    // Loan asset configuration for settlement on loan chains
    function setLoanAsset(address asset) external;
    function loanAsset() external view returns (address);

    function setPermit2(address permit2) external;

    // LBO fee configuration
    function setLBOLenderFeeBps(uint256 bps) external;
    function setLBOProtocolFeeBps(uint256 bps) external;

    // External adapters
    function setExternalAdapter(bytes32 key, address facet) external;
}


