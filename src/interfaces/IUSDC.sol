pragma solidity ^0.8.27;

interface IUSDC {
    function isBlacklisted(address user) external view returns (bool);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
}