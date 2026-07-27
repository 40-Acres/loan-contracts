// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IPortfolioFactory {
    function isPortfolio(address _portfolio) external view returns (bool);
}

/**
 * @title FortyAcresBatchRouter
 * @notice Fans a single calldata blob into N independent single-pair aggregator fills.
 */
contract FortyAcresBatchRouter is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Swap {
        address inputToken;
        uint256 inputAmount;
        address swapTarget;
        bytes swapData;
    }

    struct RouterData {
        mapping(address => bool) approvedTargets;
        EnumerableSet.AddressSet approvedTargetsList;
        mapping(address => bool) approvedCallers;
        EnumerableSet.AddressSet approvedCallersList;
        address approvedFactory;
    }

    bytes32 private constant ROUTER_STORAGE_POSITION = keccak256("storage.FortyAcresBatchRouter");

    event TargetApprovalSet(address indexed target, bool approved);
    event CallerApprovalSet(address indexed caller, bool approved);
    event FactoryApprovalSet(address indexed factory, bool approved);
    event BatchSwap(address indexed caller, uint256 swaps, uint256 outputs);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error TargetNotApproved(address target);
    error InvalidTarget(address target);
    error ZeroAmount(uint256 index);
    error LengthMismatch();
    error InsufficientOutput(address token, uint256 received, uint256 minimum);
    error Expired(uint256 deadline);
    error InputAmountMismatch(address token, uint256 expected, uint256 received);
    error InputIsOutput(address token);
    error DuplicateOutput(address token);
    error CallerNotApproved(address caller);
    error ZeroMinOut(uint256 index);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner, address initialTarget, address initialCaller, address initialFactory)
        public
        initializer
    {
        __Ownable_init(owner);
        __ReentrancyGuard_init();
        _setApprovedTarget(initialTarget, true);
        if (initialCaller != address(0)) _setApprovedCaller(initialCaller, true);
        if (initialFactory != address(0)) _setApprovedFactory(initialFactory);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _getRouterData() internal pure returns (RouterData storage routerData) {
        bytes32 position = ROUTER_STORAGE_POSITION;
        assembly {
            routerData.slot := position
        }
    }

    /**
     * @notice Execute a batch of single-pair swaps and return all proceeds to the caller.
     * @dev All-or-nothing: any failing leg reverts the whole batch, matching the semantics
     *      of the single-blob aggregator call this replaces.
     * @param swaps One entry per input token. Each carries its own target and calldata.
     * @param outputTokens Tokens whose balance delta is checked and forwarded to the caller.
     * @param minOuts Minimum delta per output token, index-aligned with `outputTokens`.
     * @param deadline Latest block timestamp at which this batch may execute.
     * @return outs Realized balance delta per output token.
     */
    function swapMulti(
        Swap[] calldata swaps,
        address[] calldata outputTokens,
        uint256[] calldata minOuts,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory outs) {
        if (!_isApprovedCaller(msg.sender)) revert CallerNotApproved(msg.sender);
        if (block.timestamp > deadline) revert Expired(deadline);
        if (outputTokens.length != minOuts.length) revert LengthMismatch();
        if (outputTokens.length == 0) revert LengthMismatch();

        uint256[] memory balancesBefore = new uint256[](outputTokens.length);
        for (uint256 i = 0; i < outputTokens.length; i++) {
            if (minOuts[i] == 0) revert ZeroMinOut(i);
            for (uint256 j = 0; j < i; j++) {
                if (outputTokens[j] == outputTokens[i]) revert DuplicateOutput(outputTokens[i]);
            }
            balancesBefore[i] = IERC20(outputTokens[i]).balanceOf(address(this));
        }

        for (uint256 i = 0; i < swaps.length; i++) {
            _executeSwap(swaps[i], i, outputTokens);
        }

        outs = new uint256[](outputTokens.length);
        for (uint256 i = 0; i < outputTokens.length; i++) {
            uint256 balanceAfter = IERC20(outputTokens[i]).balanceOf(address(this));
            outs[i] = balanceAfter - balancesBefore[i];
            if (outs[i] < minOuts[i]) revert InsufficientOutput(outputTokens[i], outs[i], minOuts[i]);
        }

        for (uint256 i = 0; i < outputTokens.length; i++) {
            if (outs[i] > 0) {
                IERC20(outputTokens[i]).safeTransfer(msg.sender, outs[i]);
            }
        }

        emit BatchSwap(msg.sender, swaps.length, outputTokens.length);
    }

    function _executeSwap(Swap calldata swap, uint256 index, address[] calldata outputTokens) internal {
        if (swap.inputAmount == 0) revert ZeroAmount(index);
        if (!_getRouterData().approvedTargets[swap.swapTarget]) revert TargetNotApproved(swap.swapTarget);
        if (swap.swapTarget == swap.inputToken || swap.swapTarget == address(this)) {
            revert InvalidTarget(swap.swapTarget);
        }
        for (uint256 i = 0; i < outputTokens.length; i++) {
            if (swap.swapTarget == outputTokens[i]) revert InvalidTarget(swap.swapTarget);
            if (swap.inputToken == outputTokens[i]) revert InputIsOutput(swap.inputToken);
        }

        IERC20 token = IERC20(swap.inputToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), swap.inputAmount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        // Rebasing and fee-on-transfer inputs fail here rather than inside the aggregator.
        if (received != swap.inputAmount) {
            revert InputAmountMismatch(swap.inputToken, swap.inputAmount, received);
        }

        token.forceApprove(swap.swapTarget, swap.inputAmount);
        (bool ok, bytes memory ret) = swap.swapTarget.call(swap.swapData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        token.forceApprove(swap.swapTarget, 0);

        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter > balanceBefore) {
            token.safeTransfer(msg.sender, balanceAfter - balanceBefore);
        }
    }

    /// @dev Static callers (loan proxies) plus any live account of the approved factory.
    function _isApprovedCaller(address caller) internal view returns (bool) {
        RouterData storage routerData = _getRouterData();
        if (routerData.approvedCallers[caller]) return true;
        address factory = routerData.approvedFactory;
        return factory != address(0) && IPortfolioFactory(factory).isPortfolio(caller);
    }

    function isApprovedCaller(address caller) public view returns (bool) {
        return _isApprovedCaller(caller);
    }

    function setApprovedCaller(address caller, bool approved) public onlyOwner {
        _setApprovedCaller(caller, approved);
    }

    function _setApprovedCaller(address caller, bool approved) internal {
        RouterData storage routerData = _getRouterData();
        routerData.approvedCallers[caller] = approved;
        if (approved) {
            routerData.approvedCallersList.add(caller);
        } else {
            routerData.approvedCallersList.remove(caller);
        }
        emit CallerApprovalSet(caller, approved);
    }

    /// @notice Set or replace the account factory; zero address disables factory-based callers.
    function setApprovedFactory(address factory) public onlyOwner {
        _setApprovedFactory(factory);
    }

    function _setApprovedFactory(address factory) internal {
        if (factory != address(0) && factory.code.length == 0) revert InvalidTarget(factory);
        _getRouterData().approvedFactory = factory;
        emit FactoryApprovalSet(factory, factory != address(0));
    }

    function getApprovedFactory() public view returns (address) {
        return _getRouterData().approvedFactory;
    }

    function setApprovedTarget(address target, bool approved) public onlyOwner {
        _setApprovedTarget(target, approved);
    }

    function _setApprovedTarget(address target, bool approved) internal {
        if (approved) {
            if (target == address(0) || target == address(this) || target.code.length == 0) {
                revert InvalidTarget(target);
            }
            // Reject ERC20-shaped targets.
            (bool ok, bytes memory ret) =
                target.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
            if (ok && ret.length >= 32) revert InvalidTarget(target);
        }
        RouterData storage routerData = _getRouterData();
        routerData.approvedTargets[target] = approved;
        if (approved) {
            routerData.approvedTargetsList.add(target);
        } else {
            routerData.approvedTargetsList.remove(target);
        }
        emit TargetApprovalSet(target, approved);
    }

    /// @notice Recover tokens stranded.
    function rescue(address token, address to) public onlyOwner {
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    function isApprovedTarget(address target) public view returns (bool) {
        return _getRouterData().approvedTargets[target];
    }

    function getApprovedTargetsList() public view returns (address[] memory) {
        return _getRouterData().approvedTargetsList.values();
    }
}
