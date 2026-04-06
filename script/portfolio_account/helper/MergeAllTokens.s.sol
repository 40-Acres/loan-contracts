// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";

interface IVeAERO {
    function balanceOf(address owner) external view returns (uint256);
    function ownerToNFTokenIdList(address owner, uint256 index) external view returns (uint256);
}

/**
 * @title MergeAllTokens
 * @dev Merges all caller's veAERO tokens into a single target token.
 *
 * Usage:
 *   PRIVATE_KEY=0x... forge script script/portfolio_account/helper/MergeAllTokens.s.sol:MergeAllTokens --sig "run(uint256)" 64196 --rpc-url $BASE_RPC_URL --broadcast
 */
contract MergeAllTokens is Script {
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    IVotingEscrow constant ve = IVotingEscrow(VOTING_ESCROW);
    IVeAERO constant veEnum = IVeAERO(VOTING_ESCROW);
    IVoter constant voter = IVoter(VOTER);

    function run(uint256 targetTokenId) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(privateKey);

        uint256 count = veEnum.balanceOf(caller);
        console.log("Caller:", caller);
        console.log("Total tokens:", count);
        console.log("Merging into:", targetTokenId);

        // Collect all token IDs except target
        uint256[] memory toMerge = new uint256[](count);
        uint256 mergeCount;
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = veEnum.ownerToNFTokenIdList(caller, i);
            if (tokenId != targetTokenId) {
                toMerge[mergeCount] = tokenId;
                mergeCount++;
            }
        }

        console.log("Tokens to merge:", mergeCount);

        vm.startBroadcast(privateKey);

        // Reset votes before unlocking (unlockPermanent requires no active votes)
        console.log("  Resetting & unlocking target token:", targetTokenId);
        voter.reset(targetTokenId);
        ve.unlockPermanent(targetTokenId);

        for (uint256 i = 0; i < mergeCount; i++) {
            console.log("  Resetting, unlocking & merging token:", toMerge[i]);
            voter.reset(toMerge[i]);
            ve.unlockPermanent(toMerge[i]);
            ve.merge(toMerge[i], targetTokenId);
        }

        vm.stopBroadcast();

        console.log("Done! All tokens merged into", targetTokenId);
    }
}
