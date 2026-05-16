// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {ERC4626CollateralManager} from "./ERC4626CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";

/**
 * @title ERC4626LendingFacet
 * @dev Facet for borrowing against ERC4626 vault share collateral.
 *      Uses ERC4626CollateralManager for debt tracking.
 */
contract ERC4626LendingFacet is AccessControl {
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

    constructor(address portfolioFactory, address lendingToken, address vault) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(lendingToken != address(0), "Invalid lending token");
        require(vault != address(0), "Invalid vault");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _lendingToken = IERC20(lendingToken);
        _vault = vault;
    }

    /**
     * @dev Borrow against ERC4626 collateral
     * @param amount The amount to borrow
     */
    function borrow(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        SequencerLivenessLib.assertUp(config);
        (uint256 amountAfterFees, uint256 originationFee) = ERC4626CollateralManager.increaseTotalDebt(
            config,
            _vault,
            amount
        );

        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        _lendingToken.safeTransfer(portfolioOwner, amountAfterFees);

        emit Borrowed(amount, amountAfterFees, originationFee, portfolioOwner);
    }

    /**
     * @dev Pay back debt
     * @param amount The amount to pay
     */
    function pay(uint256 amount) external nonReentrant returns (uint256 excess) {
        // If caller is portfolio manager, use portfolio owner as from address
        address from = msg.sender == address(_portfolioFactory.portfolioManager())
            ? _portfolioFactory.ownerOf(address(this))
            : msg.sender;

        // Cap to total debt before pulling funds. Excess-refund logic below
        // remains as defense-in-depth for race conditions where the vault
        // implicitly reduces debt during payFromPortfolio.
        uint256 totalDebt = ICollateralFacet(address(this)).getTotalDebt();
        if (amount > totalDebt) {
            amount = totalDebt;
        }

        _lendingToken.safeTransferFrom(from, address(this), amount);

        excess = ERC4626CollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), _vault, amount);

        emit Paid(amount - excess, from);

        if (excess > 0) {
            _lendingToken.safeTransfer(from, excess);
        }

        return excess;
    }

    /**
     * @dev Get the maximum loan amount
     */
    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return ERC4626CollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()), _vault);
    }

    /**
     * @dev Get total debt
     */
    function getTotalDebt() external view returns (uint256) {
        return ERC4626CollateralManager.getTotalDebt();
    }
}
