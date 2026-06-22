// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {DynamicERC4626CollateralManager} from "./DynamicERC4626CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";
import {UserLendingConfig} from "../lending/UserLendingConfig.sol";

/**
 * @title DynamicERC4626LendingFacet
 * @dev Borrowing against ERC4626 vault-share collateral on a live-debt-read
 *      lending pool. Mirrors ERC4626LendingFacet; binds DynamicERC4626CollateralManager.
 */
contract DynamicERC4626LendingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IERC20 public immutable _lendingToken;
    address public immutable _vault;

    error ReentrantCall();

    bytes32 private constant _LENDING_REENTRANCY_SLOT = keccak256("fortyacres.lending.reentrancy");

    modifier nonReentrant() {
        bytes32 slot = _LENDING_REENTRANCY_SLOT;
        uint256 status;
        assembly { status := sload(slot) }
        if (status == 2) revert ReentrantCall();
        assembly { sstore(slot, 2) }
        _;
        assembly { sstore(slot, 1) }
    }

    event Borrowed(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner);
    event Paid(uint256 amount, address indexed owner);
    event TopUpSet(bool topUpEnabled, address indexed owner);
    event ToppedUp(uint256 amount, uint256 amountAfterFees, uint256 originationFee, address indexed owner);

    constructor(address portfolioFactory, address lendingToken, address vault) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(lendingToken != address(0), "Invalid lending token");
        require(vault != address(0), "Invalid vault");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _lendingToken = IERC20(lendingToken);
        _vault = vault;
    }

    function borrow(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        SequencerLivenessLib.assertUp(config);
        (uint256 amountAfterFees, uint256 originationFee) = DynamicERC4626CollateralManager.increaseTotalDebt(
            config,
            _vault,
            amount
        );

        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);

        emit Borrowed(amount, amountAfterFees, originationFee, portfolioOwner);
    }

    function pay(uint256 amount) external nonReentrant returns (uint256) {
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        // Cap to total debt before pulling funds. Excess-refund logic below
        // remains as defense-in-depth for race conditions where the vault
        // implicitly reduces debt during payFromPortfolio.
        uint256 requestedAmount = amount;
        uint256 totalDebt = ICollateralFacet(address(this)).getTotalDebt();
        if (amount > totalDebt) {
            amount = totalDebt;
        }

        _lendingToken.safeTransferFrom(from, address(this), amount);

        uint256 postExcess = DynamicERC4626CollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), _vault, amount);
        uint256 actuallyPaid = amount - postExcess;

        emit Paid(actuallyPaid, from);

        if (postExcess > 0) {
            _lendingToken.safeTransfer(from, postExcess);
        }

        // Reported excess is the full unspent portion of the caller's request,
        // including the part capped before the transfer.
        return requestedAmount - actuallyPaid;
    }

    function setTopUp(bool topUpEnabled) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserLendingConfig.setTopUp(topUpEnabled);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit TopUpSet(topUpEnabled, owner);
    }

    function topUp() external onlyAuthorizedCaller(_portfolioFactory) {
        if (!UserLendingConfig.getTopUp()) return;

        address config = address(_portfolioFactory.portfolioFactoryConfig());
        SequencerLivenessLib.assertUp(config);

        (uint256 maxLoan, ) = DynamicERC4626CollateralManager.getMaxLoan(config, _vault);
        if (maxLoan == 0) return;

        (uint256 amountAfterFees, uint256 originationFee) =
            DynamicERC4626CollateralManager.increaseTotalDebt(config, _vault, maxLoan);

        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);

        emit ToppedUp(maxLoan, amountAfterFees, originationFee, portfolioOwner);
    }

    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return DynamicERC4626CollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()), _vault);
    }

    function getTotalDebt() external view returns (uint256) {
        return DynamicERC4626CollateralManager.getTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()));
    }
}
