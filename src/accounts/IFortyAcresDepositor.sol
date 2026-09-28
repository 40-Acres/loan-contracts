// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IFortyAcresDepositor
 * @notice The single, fixed spender users approve to deposit into a 40 Acres
 *         portfolio account. See {FortyAcresDepositor}.
 */
interface IFortyAcresDepositor {
    event Deposited721(
        address indexed factory, address indexed portfolio, address indexed user, address token, uint256 tokenId
    );
    event Deposited20(
        address indexed factory, address indexed portfolio, address indexed user, address token, uint256 amount
    );

    error NoManagers();
    error ZeroAddress();
    error FactoryNotRegistered(address factory);

    /// @notice Moves `tokenId` of `token` from msg.sender into msg.sender's
    ///         portfolio at `factory`, creating the portfolio first if needed.
    ///         Only the caller's own assets, only into the caller's own account.
    function deposit721(address factory, address token, uint256 tokenId) external returns (address portfolio);

    /// @notice Same for `amount` of ERC20 `token`.
    function deposit20(address factory, address token, uint256 amount) external returns (address portfolio);

    /// @notice PortfolioManagers fixed at construction. Only their factories are accepted.
    function getManagers() external view returns (address[] memory);

    /// @notice True when `factory` is registered with one of the managers.
    function isRegisteredFactory(address factory) external view returns (bool);

    /// @notice `user`'s portfolio at `factory`, or address(0) if not created yet.
    function portfolioOf(address factory, address user) external view returns (address);

    /// @notice True when `owner` made this contract an operator for all their
    ///         `token` NFTs, or approved it for `tokenId` specifically.
    function isApproved721(address token, address owner, uint256 tokenId) external view returns (bool);

    /// @notice `owner`'s ERC20 allowance to this contract for `token`.
    function allowance20(address token, address owner) external view returns (uint256);
}
