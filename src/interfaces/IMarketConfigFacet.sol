// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketConfigFacet {
    // Events
    event PaymentTokenAllowed(address indexed token, bool allowed);
    event MarketFeeChanged(uint16 newBps);
    event FeeRecipientChanged(address newRecipient);
    event MarketInitialized(address loan, address votingEscrow, uint16 marketFeeBps, address feeRecipient, address defaultPaymentToken);
    event MarketPauseStatusChanged(bool isPaused);
    event LoanAssetSet(address asset);

    // Initializer
    function initMarket(
        address loan,
        address votingEscrow,
        uint16 marketFeeBps,
        address feeRecipient,
        address defaultPaymentToken
    ) external;

    // Admin
    function setMarketFee(uint16 bps) external;
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
}


