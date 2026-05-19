// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHydrexVoter {
    error EpochFlipInProgress();
    error EpochStale();
    error InsufficientVotingPower();
    error LengthMismatch();
    error VotedAlready();
    error VoteDelayNotMet();

    function vote(address[] calldata pools, uint256[] calldata weights) external;
    function reset() external;
    function poke() external;

    function lastVoted(address account) external view returns (uint256);
    function votes(address account, address pool) external view returns (uint256);

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external;
    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external;
}
