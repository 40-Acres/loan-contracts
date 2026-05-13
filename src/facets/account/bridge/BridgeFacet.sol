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
 * @dev Facet that bridges USDC between chains via CCTP.
 *      Non-USDC tokens are first converted to USDC in a separate `swapMultiple` call.
 */
contract BridgeFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    ITokenMessenger public immutable _tokenMessenger;
    IERC20 public immutable _token;
    SwapConfig public immutable _swapConfig;
    uint32 public immutable _destinationDomain;

    error NotApprovedBridge(address bridgeContract);

    event SwapFailed(uint256 inputAmount, address indexed inputToken, address outputToken, address indexed owner);

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

    /**
     * @dev Swaps a batch of input tokens to USDC.
     */
    function swapMultiple(SwapMod.RouteParams[] memory params) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 amount) {
        address outputToken = address(_token);
        for (uint256 i = 0; i < params.length; i++) {
            if (params[i].inputToken == outputToken) continue;
            if (!_isSwapAllowed(params[i].inputToken)) continue;
            try SwapMod.swap(SwapMod.RouteParams({
                swapConfig: address(_swapConfig),
                swapTarget: params[i].swapTarget,
                swapData: params[i].swapData,
                inputToken: params[i].inputToken,
                inputAmount: params[i].inputAmount,
                outputToken: outputToken,
                minimumOutputAmount: params[i].minimumOutputAmount
            })) returns (uint256 swappedAmount) {
                amount += swappedAmount;
            } catch {
                emit SwapFailed(params[i].inputAmount, params[i].inputToken, outputToken, _portfolioFactory.ownerOf(address(this)));
                continue;
            }
        }
        return amount;
    }

    /**
     * @dev Returns true if the input token is allowed for swapping.
     *      Returns true by default — override in subclasses to block specific tokens.
     */
    function _isSwapAllowed(address) internal view virtual returns (bool) {
        return true;
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
