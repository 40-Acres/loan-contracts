// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../libraries/storage/MarketStorage.sol";
import {Errors} from "../libraries/Errors.sol";

interface IPermit2 {
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitSingle { TokenPermissions permitted; uint256 nonce; uint256 deadline; address spender; }
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
    function allowance(address owner, address token, address spender) external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}

library Permit2Lib {
    function getPermit2() internal view returns (address) {
        return MarketStorage.configLayout().permit2;
    }

    function decode(bytes memory optionalPermit2)
        internal
        pure
        returns (IPermit2.PermitSingle memory p2, bytes memory sig, bool has)
    {
        if (optionalPermit2.length == 0) {
            return (p2, sig, false);
        }
        (p2, sig) = abi.decode(optionalPermit2, (IPermit2.PermitSingle, bytes));
        return (p2, sig, true);
    }

    function permitAndPull(address owner, address to, address token, uint256 amount, bytes memory optionalPermit2) internal {
        (IPermit2.PermitSingle memory p2, bytes memory sig, bool has) = decode(optionalPermit2);
        if (has) {
            address permit2 = getPermit2();
            if (permit2 == address(0)) revert Errors.Permit2NotSet();
            // If an allowance already exists for this spender and is sufficient and not expired, skip the permit
            (uint160 allowed, uint48 expiration, ) = IPermit2(permit2).allowance(owner, token, address(this));
            bool allowanceValid = allowed >= uint160(amount) && (expiration == type(uint48).max || expiration >= block.timestamp);
            if (!allowanceValid) {
                IPermit2(permit2).permit(owner, p2, sig);
            }
            IPermit2(permit2).transferFrom(owner, to, uint160(amount), token);
        }
    }
}


