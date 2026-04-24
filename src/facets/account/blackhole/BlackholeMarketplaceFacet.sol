// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketplaceFacet} from "../marketplace/MarketplaceFacet.sol";
import {IVoter} from "../../../Blackhole/interfaces/IVoter.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";

/**
 * @title BlackholeMarketplaceFacet
 * @dev MarketplaceFacet variant for Blackhole/SuperNova VEs that block transfers
 *      for tokens with active votes. Calls voter.reset() before transferring
 *      the NFT to the buyer, and checks same-epoch votes in isListingPurchasable.
 */
contract BlackholeMarketplaceFacet is MarketplaceFacet {
    IVoter public immutable _voter;

    constructor(
        address portfolioFactory,
        address votingEscrow,
        address marketplace,
        address voter
    ) MarketplaceFacet(portfolioFactory, votingEscrow, marketplace) {
        require(voter != address(0));
        _voter = IVoter(voter);
    }

    /**
     * @dev Reset votes before transfer. Blackhole VEs block safeTransferFrom
     *      when the token has active votes. This mirrors the pattern in
     *      BlackholeVotingEscrowFacet.mergeInternal().
     *      Note: reset() forfeits unclaimed voting rewards for the current epoch.
     */
    function _prepareTokenForTransfer(uint256 tokenId) internal override {
       try  _voter.reset(tokenId) {} catch {}
    }

    /**
     * @dev Returns true if the token was voted in the current epoch.
     *      Blackhole's voter.reset() reverts with "VOTED" when called in the
     *      same epoch as the vote, so the listing is not purchasable until
     *      the next epoch.
     */
    function _hasCurrentEpochVote(uint256 tokenId) internal view returns (bool) {
        uint256 lastVoted = _voter.lastVoted(tokenId);
        if (lastVoted == 0) return false;
        return ProtocolTimeLibrary.epochStart(lastVoted) >= ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    /**
     * @dev Blackhole VEs block transfers for tokens voted in the current epoch,
     *      so a same-epoch vote makes the listing unpurchasable until the next epoch.
     */
    function isListingPurchasable(uint256 tokenId)
        external
        view
        override
        returns (bool purchasable, uint256 requiredPayment, uint256 netPayment)
    {
        (purchasable, requiredPayment, netPayment) = _isListingPurchasable(tokenId);
        if (purchasable && _hasCurrentEpochVote(tokenId)) {
            return (false, requiredPayment, netPayment);
        }
    }
}
