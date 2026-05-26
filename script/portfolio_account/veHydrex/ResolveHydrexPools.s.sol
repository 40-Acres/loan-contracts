// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IVoterEnum {
    function length() external view returns (uint256);
    function pools(uint256 index) external view returns (address);
    function isAlive(address gauge) external view returns (bool);
    function gauges(address pool) external view returns (address);
}

interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function symbol() external view returns (string memory);
}

interface IERC20Sym {
    function symbol() external view returns (string memory);
}

/**
 * @dev Read-only enumerator for Hydrex Voter pools. Prints `<index> <pool> <SYM0>/<SYM1> [alive=...]`
 *      so the operator can match the human-readable pair list against on-chain addresses and
 *      paste the resulting address array into DeployVeHydrexSimple.
 *
 *      Run:
 *        forge script script/portfolio_account/veHydrex/ResolveHydrexPools.s.sol:ResolveHydrexPools \
 *          --chain-id 8453 --rpc-url $BASE_RPC_URL --via-ir
 */
contract ResolveHydrexPools is Script {
    address public constant HYDREX_VOTER = 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b;

    function run() external view {
        IVoterEnum voter = IVoterEnum(HYDREX_VOTER);
        uint256 len = voter.length();
        console.log("HYDREX_VOTER pool count:", len);

        for (uint256 i = 0; i < len; i++) {
            address pool = _safePool(voter, i);
            if (pool == address(0)) {
                console.log(i, address(0), "<pools(i) reverted>");
                continue;
            }
            (string memory sym0, string memory sym1) = _tokenSymbols(pool);
            bool alive = _safeAlive(voter, pool);
            console.log(i, pool, string.concat(sym0, "/", sym1), alive ? "alive" : "dead");
        }
    }

    function _safePool(IVoterEnum voter, uint256 i) internal view returns (address pool) {
        try voter.pools(i) returns (address p) { pool = p; } catch { pool = address(0); }
    }

    function _safeAlive(IVoterEnum voter, address pool) internal view returns (bool) {
        address gauge;
        try voter.gauges(pool) returns (address g) { gauge = g; } catch { return false; }
        if (gauge == address(0)) return false;
        try voter.isAlive(gauge) returns (bool a) { return a; } catch { return false; }
    }

    function _tokenSymbols(address pool) internal view returns (string memory s0, string memory s1) {
        address t0;
        address t1;
        try IPool(pool).token0() returns (address a) { t0 = a; } catch { s0 = "?"; }
        try IPool(pool).token1() returns (address a) { t1 = a; } catch { s1 = "?"; }
        if (t0 != address(0)) {
            try IERC20Sym(t0).symbol() returns (string memory v) { s0 = v; } catch { s0 = "?"; }
        }
        if (t1 != address(0)) {
            try IERC20Sym(t1).symbol() returns (string memory v) { s1 = v; } catch { s1 = "?"; }
        }
        if (bytes(s0).length == 0) s0 = "?";
        if (bytes(s1).length == 0) s1 = "?";
    }
}
