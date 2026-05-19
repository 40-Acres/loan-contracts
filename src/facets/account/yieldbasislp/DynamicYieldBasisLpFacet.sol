// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {DynamicYieldBasisCollateralManager} from "./DynamicYieldBasisCollateralManager.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
import {YieldBasisPortfolioFactoryConfig} from "../config/YieldBasisPortfolioFactoryConfig.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title DynamicYieldBasisLpFacet
 * @dev LP deposit / withdraw / gauge staking facet for YieldBasis markets backed
 *      by a vault that tracks debt in its own storage (DynamicFeesVault and
 *      future variants implementing ILendingPool with live debt reads).
 *
 *      Mirrors YieldBasisLpFacet's external API one-to-one. The only difference
 *      is the collateral-manager library it delegates to: this facet uses
 *      DynamicYieldBasisCollateralManager so getTotalDebt reads from the pool
 *      every call rather than from a local cache.
 */
contract DynamicYieldBasisLpFacet is AccessControl, ICollateralFacet, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IERC20 public immutable _lpToken;
    address public immutable _rewardToken;
    address public immutable _underlying;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Unstaked(uint256 assets, uint256 sharesBurned);
    event Staked(uint256 assets, uint256 sharesMinted);

    /// @dev `_underlying` is derived from `lendingPool.lendingAsset()` so that
    ///      collateral pricing (via LP pricePerShare) and debt comparisons
    ///      (via lendingPool) share the same denomination by construction.
    constructor(address portfolioFactory, address gauge, address rewardToken, address lendingPool) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        require(rewardToken != address(0), "Invalid reward token");
        require(lendingPool != address(0), "Invalid lending pool");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IERC20(IYieldBasisGauge(gauge).asset());
        _rewardToken = rewardToken;
        _underlying = ILendingPool(lendingPool).lendingAsset();
    }

    function _config() internal view returns (address) {
        return address(_portfolioFactory.portfolioFactoryConfig());
    }

    function getStakedMode() public view returns (bool) {
        return YieldBasisPortfolioFactoryConfig(_config()).getStakedGaugeMode();
    }

    function deposit(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        address owner = _portfolioFactory.ownerOf(address(this));
        IERC20(address(_lpToken)).safeTransferFrom(owner, address(this), amount);

        DynamicYieldBasisCollateralManager.addCollateral(_config(), address(_lpToken), address(_gauge), _underlying, amount);

        emit Deposited(owner, amount);
        if (getStakedMode()) {
            _stake(amount);
        }
    }

    function withdraw(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        address config = _config();
        SequencerLivenessLib.assertUp(config);

        uint256 trackedShares = DynamicYieldBasisCollateralManager.getCollateralShares();
        uint256 toWithdraw = amount > trackedShares ? trackedShares : amount;
        if (toWithdraw == 0) return;

        DynamicYieldBasisCollateralManager.removeCollateral(config, address(_lpToken), _underlying, toWithdraw);

        uint256 directLp = _lpToken.balanceOf(address(this));
        if (toWithdraw > directLp) {
            uint256 shortfall = toWithdraw - directLp;
            _gauge.withdraw(shortfall, address(this), address(this));
        }

        address owner = _portfolioFactory.ownerOf(address(this));
        _lpToken.safeTransfer(owner, toWithdraw);
        emit Withdrawn(owner, toWithdraw);
    }

    function setStakedMode() external onlyAuthorizedCaller(_portfolioFactory) nonReentrant {
        bool staked = getStakedMode();
        if (staked) {
            uint256 lpBalance = _lpToken.balanceOf(address(this));
            require(lpBalance > 0, "Nothing to stake");
            _stake(lpBalance);
        } else {
            uint256 shares = _gauge.balanceOf(address(this));
            require(shares > 0, "Nothing staked");

            uint256 lpBefore = _lpToken.balanceOf(address(this));
            _gauge.redeem(shares, address(this), address(this));
            uint256 lpReceived = _lpToken.balanceOf(address(this)) - lpBefore;

            DynamicYieldBasisCollateralManager.reconcileSharesToBalance(
                _config(),
                address(_lpToken),
                _underlying,
                address(_gauge)
            );

            emit Unstaked(lpReceived, shares);
        }
    }

    function _stake(uint256 amount) internal {
        uint256 lpBefore = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(_gauge), amount);
        uint256 sharesMinted = _gauge.deposit(amount, address(this));
        _lpToken.approve(address(_gauge), 0);
        uint256 lpSent = lpBefore - _lpToken.balanceOf(address(this));
        emit Staked(lpSent, sharesMinted);
    }

    function getStakingState() external view returns (uint256 staked, uint256 unstaked) {
        staked = _gauge.balanceOf(address(this));
        unstaked = _lpToken.balanceOf(address(this));
    }

    // ============ ICollateralFacet ============

    function getTotalLockedCollateral() external view override returns (uint256) {
        return DynamicYieldBasisCollateralManager.getTotalCollateralValue(address(_lpToken), _underlying);
    }

    function getTotalDebt() external view override returns (uint256) {
        return DynamicYieldBasisCollateralManager.getTotalDebt(_config());
    }

    function getMaxLoan() external view override returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return DynamicYieldBasisCollateralManager.getMaxLoan(_config(), address(_lpToken), _underlying);
    }

    function enforceCollateralRequirements() external view override returns (bool success) {
        return DynamicYieldBasisCollateralManager.enforceCollateralRequirements(_config(), address(_lpToken), _underlying);
    }

    function getLoanUtilization() external view override returns (uint256) {
        return DynamicYieldBasisCollateralManager.getLoanUtilization(_config(), address(_lpToken), _underlying);
    }

    function getCollateralToken() external view override returns (address) {
        return address(_lpToken);
    }
}
