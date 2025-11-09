pragma solidity ^0.8.27;

interface IUSDC {
    function isBlacklisted(address user) external view returns (bool);
}