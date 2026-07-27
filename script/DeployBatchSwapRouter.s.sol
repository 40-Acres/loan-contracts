// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {FortyAcresBatchRouter} from "../src/swap/FortyAcresBatchRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @dev Deploy FortyAcresBatchRouter (impl + UUPS proxy) on Avalanche.
 *      Initialized with the deployer so extra targets can be seeded in the same
 *      broadcast, then handed to the multisig; the multisig must call
 *      acceptOwnership() to finalize.
 *      Optional env: APPROVED_SWAP_TARGETS (comma-separated) replaces the default set.
 *
 * =====================================================================================
 * ODOS EOL MIGRATION RUNBOOK (Avalanche 43114) -- Odos API dark 2026-07-30
 * =====================================================================================
 *
 * WHAT SHIPS
 *   1. FortyAcresBatchRouter (this script)             -- new UUPS proxy
 *   2. BlackholeLoanV2 impl                            -- upgrade Blackhole loan proxy
 *   3. XPharaohFacet                                   -- replaceFacet in the registry
 *   (XPharaohLoan is NOT touched: its _processRewards delegates the swap to the facet.)
 *
 * KEY ADDRESSES
 *   deployer (FORTY_ACRES_DEPLOYER)  0x40FecA5f7156030b78200450852792ea93f7c6cd
 *   Safe (owner, 2-of-3)             0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23
 *   LIVE router proxy                0x9357E52260bd5A4c704c02a285608ba6698f405F
 *   LIVE router impl                 0x6aA922Eb759C7Bc8586e5916d461a01517B93C99
 *   Blackhole loan proxy             0x5122f5154DF20E5F29df53E633cE1ac5b6623558
 *   Blackhole live impl (baseline)   0x693ab037675b056730576892c214015990440cdb
 *   XPharaoh live facet              0xef74752d36e5f54b1a1f9f14e3c9845d74f38d49
 *   FacetRegistry                    0x9bCa68D9c613Dc9B07B2727c28b5ce46204943de
 *   LoanUtils library (pin)          0x8d428b881056bc2522fe2d9ccc2ef59f3b27fc2b
 *   0x AllowanceHolder (seed target) 0x0000000000001fF3684f28c67538d4D072C22734
 *   KyberSwap router (seed target)   0x6131B5fae19EA4f9D964eAc0408E4408b66337b5
 *
 * The router (plain CREATE, nonce-based) is ALREADY LIVE at the proxy above and is baked
 * into BlackholeLoanV2.odosRouter() (branch odos-blackhole-impl) and XPharaohFacet._odosRouter
 * (main). Both were byte-diff verified: each new build differs from its baseline by ONLY the
 * router address. STEP 1 IS DONE -- do not re-run it.
 *
 * ------------------------------------------------------------------------------------
 * STEP 1 -- DONE. Router live at 0x9357E52260bd5A4c704c02a285608ba6698f405F.
 *
 * forge script script/DeployBatchSwapRouter.s.sol:DeployBatchSwapRouter \
 *  --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
 *
 * ------------------------------------------------------------------------------------
 * STEP 2 -- Blackhole loan impl. Build from branch odos-blackhole-impl (commit a794af6,
 *   off deployed baseline b2baeab). That branch ALREADY carries the one-line router repoint
 *   (BlackholeLoanV2.odosRouter() -> 0x9357E522..) and this deploy script. Byte-diff verified:
 *   the runtime differs from live impl 0x693ab0.. by ONLY the router address (6 inlined
 *   occurrences, since odosRouter() is pure-returns-constant). Pin the live LoanUtils.
 *
 *   git switch odos-blackhole-impl
 *   forge script script/DeployBlackholeOdosHotfixImpl.s.sol:DeployBlackholeOdosHotfixImpl \
 *     --libraries src/LoanUtils.sol:LoanUtils:0x8d428b881056bc2522fe2d9ccc2ef59f3b27fc2b \
 *     --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
 *
 * ------------------------------------------------------------------------------------
 * STEP 3 -- XPharaoh facet (from main; constructor args read off the live facet).
 *
 *   git switch main
 *   forge script script/RedeployXPharaohFacet.s.sol:RedeployXPharaohFacet \
 *     --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
 *
 * ------------------------------------------------------------------------------------
 * STEP 4 -- build the Safe tx-builder batch (3 txs), then import + sign (2-of-3).
 *   Args: <ROUTER_PROXY> <NEW_BLACKHOLE_IMPL> <NEW_XPHARAOH_FACET>
 *
 *   ./script/odos-migration-safe-batch.sh \
 *     0x9357E52260bd5A4c704c02a285608ba6698f405F <NEW_BLACKHOLE_IMPL> <NEW_XPHARAOH_FACET>
 *
 *   The batch executes, in order:
 *     tx1  router.acceptOwnership()                          @ router proxy
 *     tx2  proxy.upgradeToAndCall(newBlackholeImpl, "")      @ Blackhole loan proxy
 *     tx3  registry.replaceFacet(oldFacet,newFacet,sels,..)  @ FacetRegistry
 *
 * ROLLBACK
 *   - kill switch (no upgrade):  router.setApprovedTarget(<aggregator>, false) -> claims revert cleanly
 *   - router bug:               UUPS-upgrade the router (Blackhole/XPharaoh untouched)
 *   - catastrophic:             re-upgrade proxy to 0x693ab0..., replaceFacet back to 0xef74..
 *                               (NOTE: post-2026-07-30 this restores the broken Odos state)
 * =====================================================================================
 *
 * forge script script/DeployBatchSwapRouter.s.sol:DeployBatchSwapRouter \
 *   --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
 */
contract DeployBatchSwapRouter is Script {
    address public constant MULTISIG_ADDRESS = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // Same address is both the allowance target and the call target for each aggregator.
    address public constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address public constant KYBERSWAP_META_AGGREGATOR = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    address public constant BLACKHOLE_LOAN_PROXY = 0x5122f5154DF20E5F29df53E633cE1ac5b6623558;
    address public constant PHARAOH_PORTFOLIO_FACTORY = 0x52d43C377e498980135C8F2E858f120A18Ea96C2;

    function run() external {
        uint256 deployerKey = vm.envUint("FORTY_ACRES_DEPLOYER");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Plain CREATE (nonce-based). This already ran: proxy is live at
        // 0x9357E52260bd5A4c704c02a285608ba6698f405F, which is the address baked into
        // BlackholeLoanV2.odosRouter() / XPharaohFacet._odosRouter. Do NOT re-run against
        // Avalanche -- a rerun deploys a fresh router at a new nonce and breaks that match.
        FortyAcresBatchRouter impl = new FortyAcresBatchRouter();
        FortyAcresBatchRouter proxy = FortyAcresBatchRouter(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        FortyAcresBatchRouter.initialize,
                        (deployer, ZEROX_ALLOWANCE_HOLDER, BLACKHOLE_LOAN_PROXY, PHARAOH_PORTFOLIO_FACTORY)
                    )
                )
            )
        );

        address[] memory defaultApprovedTargets = new address[](1);
        defaultApprovedTargets[0] = KYBERSWAP_META_AGGREGATOR;

        address[] memory targets = vm.envOr("APPROVED_SWAP_TARGETS", ",", defaultApprovedTargets);

        for (uint256 i = 0; i < targets.length; i++) {
            if (!proxy.isApprovedTarget(targets[i])) {
                proxy.setApprovedTarget(targets[i], true);
            }
        }

        proxy.transferOwnership(MULTISIG_ADDRESS);

        console.log("FortyAcresBatchRouter impl:", address(impl));
        console.log("FortyAcresBatchRouter proxy:", address(proxy));
        console.log("Approved targets:", proxy.getApprovedTargetsList().length);
        console.log("Pending owner (must acceptOwnership()):", MULTISIG_ADDRESS);

        vm.stopBroadcast();
    }
}
