// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ICollateralFacet {
    function getTotalDebt() external view returns (uint256);
    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply);
    function enforceCollateralRequirements() external view returns (bool success);
    function getTotalLockedCollateral() external view returns (uint256);

    /// @notice Account loan utilization in basis points of borrowing capacity.
    /// @dev Computed as `(totalDebt * 100_00) / maxLoanIgnoreSupply`. Returns `0` when there is
    ///      no debt and `type(uint256).max` when capacity is zero but debt is positive.
    /// @return util `0` = no debt, `100_00` = at the borrowing limit, `>100_00` = underwater.
    function getLoanUtilization() external view returns (uint256 util);

    /// @notice Address of the asset that represents collateral on this account.
    /// @dev For veNFT variants this is the voting-escrow contract; for ERC4626 variants the
    ///      vault address; for YB-LP the LP token. The unit/semantic of `getTotalLockedCollateral`
    ///      is the value of holdings of this token denominated in the loan asset.
    function getCollateralToken() external view returns (address);
}
