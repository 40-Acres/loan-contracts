// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IVoterRead {
    function gauges(address pool) external view returns (address);
    function external_bribes(address gauge) external view returns (address);
    function internal_bribes(address gauge) external view returns (address);
}

interface IVotingReward {
    function rewardsListLength() external view returns (uint256);
    function rewardTokens(uint256 i) external view returns (address);
    function rewardData(address token, uint256 epochStart)
        external view returns (uint256 periodFinish, uint256 rewardsPerEpoch, uint256 lastUpdateTime);
}

interface IERC20Meta {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IMulticall3 {
    struct Call3 { address target; bool allowFailure; bytes callData; }
    struct Result { bool success; bytes returnData; }
    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory);
}

/**
 * @dev Multicall3-batched resolver. For each ambiguous candidate pool:
 *      1. Resolves gauge -> bribe + fees voting-reward contracts
 *      2. Enumerates each reward contract's full reward token list on-chain
 *      3. Reads balance + symbol + decimals for every (contract, token) pair
 *      4. Prints per-token balances; flags the candidate with the largest stable-coin USD-equivalent
 *
 *      Run:
 *        forge script script/portfolio_account/veHydrex/ResolveAmbiguousBribes.s.sol:ResolveAmbiguousBribes \
 *          --chain-id 8453 --rpc-url $BASE_RPC_URL --via-ir
 */
contract ResolveAmbiguousBribes is Script {
    address public constant VOTER = 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b;
    address public constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    struct Candidate { string pair; address pool; }
    struct PoolView { address gauge; address bribe; address fees; uint256 bribeLen; uint256 feesLen; }
    struct TokenView { address token; string symbol; uint8 decimals; uint256 bribeBal; uint256 feesBal; }

    function _candidates() internal pure returns (Candidate[] memory c) {
        // All ambiguous variants + all uniquely-matched picks. Any pool returning
        // zero current+next epoch bribes is a stale gauge to drop or replace.
        c = new Candidate[](58);
        uint256 i;
        // Ambiguous (4 HYDX/USDC, 4 BETR/WETH, 3 BNKR/WETH, 3 USDC/MRDN, 3 WETH/cbBTC, 2 WETH/EURC,
        //   2 USDC/cbBTC, 4 WETH/USDC, 3 WETH/FACY, 3 WETH/SERV, 3 WETH/TIBBIR, 3 WETH/DEXTF, 2 FXUSD/USDC)
        c[i++] = Candidate("HYDX/USDC",    0x79C025fA131184853B4c720cD381cD97aAbeCE11);
        c[i++] = Candidate("HYDX/USDC",    0xfF8B29e9f536F9A43DA7868011b7B667fa8d73f7);
        c[i++] = Candidate("HYDX/USDC",    0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d);
        c[i++] = Candidate("HYDX/USDC",    0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2);
        c[i++] = Candidate("BETR/WETH",    0x086745599621901C321fA6662ACA87bB5065d1a2);
        c[i++] = Candidate("BETR/WETH",    0x59FE6fb70601E9381a634aDCFAaEaBe54E19104A);
        c[i++] = Candidate("BETR/WETH",    0x81BFdCf0c7daF4e24130D8A8c3aDcF70b50427De);
        c[i++] = Candidate("BETR/WETH",    0x18156ACE9940645ebF3602E2B320a77131a70aD1);
        c[i++] = Candidate("BNKR/WETH",    0xed14CC089C687695565079E816fBAd4132BcaccE);
        c[i++] = Candidate("BNKR/WETH",    0x0f0824706b8daa0096377054D3f942ccb0d5E3D4);
        c[i++] = Candidate("BNKR/WETH",    0x680581725840958141Bb328666D8Fc185aC4FA49);
        c[i++] = Candidate("USDC/MRDN",    0xF1B9D70e54D01E10433a7D9a17361555E1e819aC);
        c[i++] = Candidate("USDC/MRDN",    0x323585Ee14a7d93676190c067fa31Ad23dEedB23);
        c[i++] = Candidate("USDC/MRDN",    0xcecf4d16114E601276Ba7E8C39A309fBfc605F0e);
        c[i++] = Candidate("WETH/cbBTC",   0xCf27Dd90878Dd88FD58bFfFCBDfBC7E0Cf7cd779);
        c[i++] = Candidate("WETH/cbBTC",   0x558684fDAd1D3b69f920b0C8E5Ae9ff797e3f045);
        c[i++] = Candidate("WETH/cbBTC",   0x3f9b863EF4B295d6Ba370215bcCa3785FCC44f44);
        c[i++] = Candidate("WETH/EURC",    0xE72258d2844Dcd3092825D51bF3C380424723B2d);
        c[i++] = Candidate("WETH/EURC",    0xB20f018Dde5A6FE7F93c31Da05a5Da9EfBc52772);
        c[i++] = Candidate("USDC/cbBTC",   0x25154C35b24aF82196bAc0D143dD973335201b6a);
        c[i++] = Candidate("USDC/cbBTC",   0x0BA69825c4C033e72309F6AC0Bde0023b15Cc97c);
        c[i++] = Candidate("WETH/USDC",    0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad);
        c[i++] = Candidate("WETH/USDC",    0x0C9be6dF4e114D5Cb04Cbb934172Be1FcC5526c6);
        c[i++] = Candidate("WETH/USDC",    0x4DC7EfB7d005DD514aCDc0a0631630b67dD83A4B);
        c[i++] = Candidate("WETH/USDC",    0x82dbe18346a8656dBB5E76F74bf3AE279cC16B29);
        c[i++] = Candidate("WETH/FACY",    0x167EbB31851509Fb7C5Ba719F9a6285F98A30329);
        c[i++] = Candidate("WETH/FACY",    0x7Dc7C66A8316f2389fEa294E55Cc2BC20F7314E5);
        c[i++] = Candidate("WETH/FACY",    0xF19787f048b3401546aa7A979afa79D555C114Dd);
        c[i++] = Candidate("WETH/SERV",    0x9B8292294C87c4dC08b708cfB6a7CdAc14287D9c);
        c[i++] = Candidate("WETH/SERV",    0x9081830774D722dd4487FA795d9C27814Dc85539);
        c[i++] = Candidate("WETH/SERV",    0x8323bA10155388825Fba72f4c81Dd6642D7321eF);
        c[i++] = Candidate("WETH/TIBBIR",  0x5c95Bb22f83400EFBEbDF9215A5B2670335cff1a);
        c[i++] = Candidate("WETH/TIBBIR",  0xA8AfD87084666453B102811aEEFD5600D89B5532);
        c[i++] = Candidate("WETH/TIBBIR",  0xB3f0828eB3375B609b49E9Fb959472a29cD6E49a);
        c[i++] = Candidate("WETH/DEXTF",   0xEd485e9e60d0E1085Eb159D15455a16ed56AbedA);
        c[i++] = Candidate("WETH/DEXTF",   0xBa1E7e092B6a02d6b0B6Ea822b5bd1255F438756);
        c[i++] = Candidate("WETH/DEXTF",   0xC3F617c8A3DA6d286c8f97aF946A8f293632C852);
        c[i++] = Candidate("FXUSD/USDC",   0xd62dD40b22DB2fB620EF81592F97864496728a51);
        c[i++] = Candidate("FXUSD/USDC",   0x4506B0e9a7b0B06185fF317cEF77bc5454B045C9);
        // Uniquely-matched picks (19) — re-verify under per-epoch model
        c[i++] = Candidate("MONSTRO/mUSDC",  0xd0a0952146dA2Fe2E3EF5898C60daA8A7bf9d1e9);
        c[i++] = Candidate("GBM/USDC",       0xb8F9Dbb4a56292811C749e53B7085fdC9856cEC0);
        c[i++] = Candidate("WETH/MILK",      0x89867ac9918d514E85d3ad906351Be90780Ce513);
        c[i++] = Candidate("wtSPYM/USDC",    0x7796fc53B75960A9762Ba267c19F5da9868B7853);
        c[i++] = Candidate("USDp/frxUSD",    0x053384cc10819B1519DabB5305Dc4711A00CfDB8);
        c[i++] = Candidate("WETH/REPPO",     0x2Df4Af05F8C4AFf0d3FbfC327595dbb7Fc6498BF);
        c[i++] = Candidate("USDC/VVV",       0x02107bAb40bBA06AE979A15f67B5AD3853c5E116);
        c[i++] = Candidate("cbBTC/wtMSTR",   0x37077D100b369Ab48c9e6B7b21c15eee4fDF9923);
        c[i++] = Candidate("WETH/MCADE",     0x6FAe4c404BE7BDd12492385498F8C6e5177e4532);
        c[i++] = Candidate("BNKR/FXUSD",     0x52fde427c2483bA0749140C0B43cfce73ba50D20);
        c[i++] = Candidate("USDC/mUSDC",     0x174B0950f7359F6197E92d8B274F0D6B27154575);
        c[i++] = Candidate("wtCOIN/USDC",    0xab5d32fF95b58bD5e77De08738a391973eE88C81);
        c[i++] = Candidate("HYDX/WETH",      0x89F29DD355d74e57389374a2AA5f9518a1e497aC);
        c[i++] = Candidate("LFI/USDC",       0x53ab4c60ff04b782F630A8685af95404f099aAFD);
        c[i++] = Candidate("USDC/MCADE",     0xE19fA51bfAF6cECC9D8B6759cA66dB399188DFa7);
        c[i++] = Candidate("AZUSD/USDC",     0x763ADCf71cB195184088A26BE01662119E303F5f);
        c[i++] = Candidate("WETH/NOCK",      0x467a8846E7B54eAC5D4D1cb2FDC9B8752212Ff0e);
        c[i++] = Candidate("wtQQQM/USDC",    0xece0d1e0615feB34e78129d1996B75f1ff082324);
        c[i++] = Candidate("tGBP/frxUSD",    0xd4610403F0a93611ca76a5847743533268efF793);
    }

    uint256 public constant WEEK = 7 days;

    function _epochStart(uint256 ts) internal pure returns (uint256) {
        return (ts / WEEK) * WEEK;
    }

    /// @dev Whole resolver runs in 5 global Multicall3 batches regardless of candidate count:
    ///        (1) gauges, (2) bribe+fees, (3) rewardsListLength,
    ///        (4) rewardTokens(i) flattened across all reward contracts,
    ///        (5) symbol+decimals+rewardData(epochNow,epochNext) flattened across all tokens.
    function run() external {
        Candidate[] memory cands = _candidates();
        uint256 n = cands.length;
        PoolView[] memory pv = new PoolView[](n);

        // Phase 1: pools -> gauges
        {
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](n);
            for (uint256 i = 0; i < n; i++) {
                calls[i] = IMulticall3.Call3({
                    target: VOTER, allowFailure: true,
                    callData: abi.encodeCall(IVoterRead.gauges, (cands[i].pool))
                });
            }
            IMulticall3.Result[] memory r = IMulticall3(MULTICALL3).aggregate3(calls);
            for (uint256 i = 0; i < n; i++) pv[i].gauge = _decodeAddress(r[i]);
        }

        // Phase 2: gauges -> bribes + fees
        {
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](n * 2);
            for (uint256 i = 0; i < n; i++) {
                calls[2*i]   = IMulticall3.Call3({
                    target: VOTER, allowFailure: true,
                    callData: abi.encodeCall(IVoterRead.external_bribes, (pv[i].gauge))
                });
                calls[2*i+1] = IMulticall3.Call3({
                    target: VOTER, allowFailure: true,
                    callData: abi.encodeCall(IVoterRead.internal_bribes, (pv[i].gauge))
                });
            }
            IMulticall3.Result[] memory r = IMulticall3(MULTICALL3).aggregate3(calls);
            for (uint256 i = 0; i < n; i++) {
                pv[i].bribe = _decodeAddress(r[2*i]);
                pv[i].fees  = _decodeAddress(r[2*i+1]);
            }
        }

        // Phase 3: rewardsListLength on each (bribe, fees)
        {
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](n * 2);
            for (uint256 i = 0; i < n; i++) {
                calls[2*i] = IMulticall3.Call3({
                    target: pv[i].bribe == address(0) ? MULTICALL3 : pv[i].bribe,
                    allowFailure: true,
                    callData: abi.encodeCall(IVotingReward.rewardsListLength, ())
                });
                calls[2*i+1] = IMulticall3.Call3({
                    target: pv[i].fees == address(0) ? MULTICALL3 : pv[i].fees,
                    allowFailure: true,
                    callData: abi.encodeCall(IVotingReward.rewardsListLength, ())
                });
            }
            IMulticall3.Result[] memory r = IMulticall3(MULTICALL3).aggregate3(calls);
            for (uint256 i = 0; i < n; i++) {
                pv[i].bribeLen = _decodeUint(r[2*i]);
                pv[i].feesLen  = _decodeUint(r[2*i+1]);
            }
        }

        // Build flat token-slot table: each slot = one (rewardContract, tokenIndex) pair across all candidates.
        // bribeStart[i], bribeLen[i], feesStart[i], feesLen[i] index into the flat table.
        uint256 totalSlots;
        for (uint256 i = 0; i < n; i++) totalSlots += pv[i].bribeLen + pv[i].feesLen;

        uint256[] memory bribeStart = new uint256[](n);
        uint256[] memory feesStart  = new uint256[](n);
        address[] memory slotReward = new address[](totalSlots);
        uint256[] memory slotIdx    = new uint256[](totalSlots);

        {
            uint256 cursor;
            for (uint256 i = 0; i < n; i++) {
                bribeStart[i] = cursor;
                for (uint256 j = 0; j < pv[i].bribeLen; j++) {
                    slotReward[cursor] = pv[i].bribe;
                    slotIdx[cursor] = j;
                    cursor++;
                }
                feesStart[i] = cursor;
                for (uint256 j = 0; j < pv[i].feesLen; j++) {
                    slotReward[cursor] = pv[i].fees;
                    slotIdx[cursor] = j;
                    cursor++;
                }
            }
        }

        // Phase 4: rewardTokens(i) across all slots
        address[] memory slotToken = new address[](totalSlots);
        {
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](totalSlots);
            for (uint256 s = 0; s < totalSlots; s++) {
                calls[s] = IMulticall3.Call3({
                    target: slotReward[s], allowFailure: true,
                    callData: abi.encodeCall(IVotingReward.rewardTokens, (slotIdx[s]))
                });
            }
            IMulticall3.Result[] memory r = IMulticall3(MULTICALL3).aggregate3(calls);
            for (uint256 s = 0; s < totalSlots; s++) slotToken[s] = _decodeAddress(r[s]);
        }

        // Phase 5: per-slot symbol + decimals + rewardData(now) + rewardData(next)
        uint256 epochNow  = _epochStart(block.timestamp);
        uint256 epochNext = epochNow + WEEK;
        string[] memory slotSym = new string[](totalSlots);
        uint8[]  memory slotDec = new uint8[](totalSlots);
        uint256[] memory slotNow  = new uint256[](totalSlots);
        uint256[] memory slotNext = new uint256[](totalSlots);
        {
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](totalSlots * 4);
            for (uint256 s = 0; s < totalSlots; s++) {
                address t = slotToken[s];
                address tt = t == address(0) ? MULTICALL3 : t;
                address rr = t == address(0) ? MULTICALL3 : slotReward[s];
                calls[4*s]   = IMulticall3.Call3({ target: tt, allowFailure: true,
                    callData: abi.encodeCall(IERC20Meta.symbol, ()) });
                calls[4*s+1] = IMulticall3.Call3({ target: tt, allowFailure: true,
                    callData: abi.encodeCall(IERC20Meta.decimals, ()) });
                calls[4*s+2] = IMulticall3.Call3({ target: rr, allowFailure: true,
                    callData: abi.encodeCall(IVotingReward.rewardData, (t, epochNow)) });
                calls[4*s+3] = IMulticall3.Call3({ target: rr, allowFailure: true,
                    callData: abi.encodeCall(IVotingReward.rewardData, (t, epochNext)) });
            }
            IMulticall3.Result[] memory r = IMulticall3(MULTICALL3).aggregate3(calls);
            for (uint256 s = 0; s < totalSlots; s++) {
                slotSym[s]  = _safeString(r[4*s]);
                slotDec[s]  = _decodeUint8(r[4*s+1], 18);
                slotNow[s]  = _decodeRewardsPerEpoch(r[4*s+2]);
                slotNext[s] = _decodeRewardsPerEpoch(r[4*s+3]);
            }
        }

        // Final pass: print per-candidate
        console.log("=== Per-candidate per-epoch bribes (rewardData.rewardsPerEpoch) ===");
        console.log("epochNow=", epochNow, " epochNext=", epochNext);
        for (uint256 i = 0; i < n; i++) {
            console.log("");
            console.log(cands[i].pair, cands[i].pool);
            console.log("  gauge:", pv[i].gauge);
            console.log("  bribe:", pv[i].bribe, "len=", pv[i].bribeLen);
            console.log("  fees: ", pv[i].fees,  "len=", pv[i].feesLen);
            _printSlots("bribe", bribeStart[i], pv[i].bribeLen, slotToken, slotSym, slotDec, slotNow, slotNext);
            _printSlots("fees ", feesStart[i], pv[i].feesLen, slotToken, slotSym, slotDec, slotNow, slotNext);
        }
    }

    function _printSlots(
        string memory tag,
        uint256 start,
        uint256 len,
        address[] memory slotToken,
        string[] memory slotSym,
        uint8[] memory slotDec,
        uint256[] memory slotNow,
        uint256[] memory slotNext
    ) internal pure {
        for (uint256 j = 0; j < len; j++) {
            uint256 s = start + j;
            address t = slotToken[s];
            if (t == address(0)) continue;
            uint256 nowAmt = slotNow[s];
            uint256 nextAmt = slotNext[s];
            if (nowAmt == 0 && nextAmt == 0) continue;
            uint256 div = 10 ** slotDec[s];
            console.log(string.concat("    [", tag, "] ", slotSym[s], " token="), t);
            console.log("      epochNow  whole=", nowAmt / div, " raw=", nowAmt);
            console.log("      epochNext whole=", nextAmt / div, " raw=", nextAmt);
        }
    }

    function _decodeRewardsPerEpoch(IMulticall3.Result memory res) internal pure returns (uint256) {
        if (!res.success || res.returnData.length < 96) return 0;
        (, uint256 rewardsPerEpoch, ) = abi.decode(res.returnData, (uint256, uint256, uint256));
        return rewardsPerEpoch;
    }

    function _decodeAddress(IMulticall3.Result memory res) internal pure returns (address) {
        if (!res.success) return address(0);
        if (res.returnData.length < 32) return address(0);
        return abi.decode(res.returnData, (address));
    }

    function _decodeUint(IMulticall3.Result memory res) internal pure returns (uint256) {
        if (!res.success) return 0;
        if (res.returnData.length < 32) return 0;
        return abi.decode(res.returnData, (uint256));
    }

    function _decodeUint8(IMulticall3.Result memory res, uint8 fallbackVal) internal pure returns (uint8) {
        if (!res.success) return fallbackVal;
        if (res.returnData.length < 32) return fallbackVal;
        return abi.decode(res.returnData, (uint8));
    }

    function _safeString(IMulticall3.Result memory res) internal pure returns (string memory) {
        if (!res.success || res.returnData.length < 64) return "?";
        return abi.decode(res.returnData, (string));
    }
}
