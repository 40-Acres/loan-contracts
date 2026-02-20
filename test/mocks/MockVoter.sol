// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title MockVoter
 * @dev Minimal Voter mock for local testing.
 *      Tracks lastVoted per tokenId, configurable isGauge.
 */
contract MockVoter {
    mapping(uint256 => uint256) public lastVoted;
    mapping(uint256 => mapping(address => uint256)) public votes;
    mapping(uint256 => uint256) public usedWeights;
    mapping(uint256 => mapping(uint256 => address)) public poolVote;
    mapping(address => bool) private _isGauge;
    mapping(address => bool) public isAlive;
    mapping(address => address) public gauges;
    mapping(address => address) public gaugeToFees;
    mapping(address => address) public gaugeToBribe;
    mapping(address => address) public feeDistributors;

    function vote(uint256 tokenId, address[] calldata, uint256[] calldata) external {
        lastVoted[tokenId] = block.timestamp;
    }

    function reset(uint256 tokenId) external {
        lastVoted[tokenId] = 0;
    }

    function poke(uint256) external {}

    function claimBribes(address[] memory, address[][] memory, uint256) external {}

    function claimFees(address[] memory, address[][] memory, uint256) external {}

    // ── Test helpers ───────────────────────────────────────────────────

    function setIsGauge(address gauge, bool value) external {
        _isGauge[gauge] = value;
    }

    function setIsAlive(address gauge, bool value) external {
        isAlive[gauge] = value;
    }

    function setGauge(address pool, address gauge) external {
        gauges[pool] = gauge;
    }

    function setLastVoted(uint256 tokenId, uint256 timestamp) external {
        lastVoted[tokenId] = timestamp;
    }
}
