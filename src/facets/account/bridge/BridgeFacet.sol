// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ITokenMessenger} from "../../../interfaces/ITokenMessenger.sol";
import {SwapMod} from "../swap/SwapMod.sol";
import {SwapConfig} from "../config/SwapConfig.sol";

/**
 * @title BridgeFacet
 * @dev Facet that bridges tokens between chains.
 *      Supports direct USDC bridging and swap-then-bridge for non-USDC tokens.
 */
contract BridgeFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    ITokenMessenger public immutable _tokenMessenger;
    IERC20 public immutable _token;
    SwapConfig public immutable _swapConfig;
    uint32 public immutable _destinationDomain;

    error NotApprovedBridge(address bridgeContract);

    constructor(address portfolioFactory, address token, address tokenMessenger, uint32 destinationDomain, address swapConfig) {
        require(portfolioFactory != address(0));
        require(tokenMessenger != address(0));
        require(token != address(0));
        require(swapConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _token = IERC20(token);
        _destinationDomain = destinationDomain; // https://developers.circle.com/cctp/cctp-supported-blockchains
        _tokenMessenger = ITokenMessenger(tokenMessenger);
        _swapConfig = SwapConfig(swapConfig);
    }

    function bridge(uint256 amount, uint256 maxFee) external onlyAuthorizedCaller(_portfolioFactory) {
        _bridge(amount, maxFee);
    }

    function swapAndBridge(SwapMod.RouteParams memory swapParams, uint256 maxBridgeFee) external onlyAuthorizedCaller(_portfolioFactory) {
        uint256 usdcAmount = SwapMod.swap(SwapMod.RouteParams({
            swapConfig: address(_swapConfig),
            swapTarget: swapParams.swapTarget,
            swapData: swapParams.swapData,
            inputToken: swapParams.inputToken,
            inputAmount: swapParams.inputAmount,
            outputToken: address(_token),
            minimumOutputAmount: swapParams.minimumOutputAmount
        }));
        _bridge(usdcAmount, maxBridgeFee);
    }

    function _bridge(uint256 amount, uint256 maxFee) internal {
        uint32 minFinalityThreshold = 2000;
        _token.approve(address(_tokenMessenger), amount);
        _tokenMessenger.depositForBurn(
            amount,
            _destinationDomain, bytes32(uint256(uint160(address(this)))),
            address(_token),
            bytes32(uint256(uint160(address(0)))),
            maxFee,
            minFinalityThreshold
        );
        _token.approve(address(_tokenMessenger), 0);
    }
}
