// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IHydrexVoter} from "../../../../src/interfaces/IHydrexVoter.sol";

/// @notice Minimal mock of Hydrex Voter used to validate facet wiring.
contract MockHydrexVoter is IHydrexVoter {
    mapping(address => uint256) internal _lastVoted;

    struct VoteCall {
        address[] pools;
        uint256[] weights;
    }

    VoteCall[] internal _voteCalls;

    struct ClaimFeesCall {
        address[] fees;
        address[][] tokens;
        uint256 tokenId;
    }
    ClaimFeesCall[] internal _claimFeesCalls;

    uint256 public resetCalls;

    function vote(address[] calldata pools, uint256[] calldata weights) external override {
        require(pools.length == weights.length, "LengthMismatch");
        _voteCalls.push(VoteCall({pools: pools, weights: weights}));
        _lastVoted[msg.sender] = block.timestamp;
    }

    function reset() external override {
        resetCalls++;
    }

    function poke() external override {}

    function lastVoted(address account) external view override returns (uint256) {
        return _lastVoted[account];
    }

    function votes(address, address) external pure override returns (uint256) {
        return 0;
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external override {
        _claimFeesCalls.push();
        ClaimFeesCall storage c = _claimFeesCalls[_claimFeesCalls.length - 1];
        for (uint256 i = 0; i < fees.length; i++) c.fees.push(fees[i]);
        for (uint256 i = 0; i < tokens.length; i++) {
            c.tokens.push();
            for (uint256 j = 0; j < tokens[i].length; j++) c.tokens[i].push(tokens[i][j]);
        }
        c.tokenId = tokenId;
    }

    function claimBribes(address[] calldata, address[][] calldata, uint256) external override {}

    // -- test helpers --
    function voteCallCount() external view returns (uint256) { return _voteCalls.length; }

    function lastVoteCall() external view returns (address[] memory pools, uint256[] memory weights) {
        require(_voteCalls.length > 0, "no votes");
        VoteCall storage c = _voteCalls[_voteCalls.length - 1];
        return (c.pools, c.weights);
    }

    function claimFeesCallCount() external view returns (uint256) { return _claimFeesCalls.length; }

    function setLastVoted(address account, uint256 ts) external { _lastVoted[account] = ts; }
}
