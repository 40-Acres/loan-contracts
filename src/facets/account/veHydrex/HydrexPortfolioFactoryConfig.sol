// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {NFTPortfolioFactoryConfig} from "../config/NFTPortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";

/**
 * @title HydrexPortfolioFactoryConfig
 * @dev Extends NFTPortfolioFactoryConfig with Hydrex-specific per-account state.
 *      Tracks the rebase-bucket tokenId per portfolio account: the PERMANENT
 *      veNFT that absorbs rebase emissions when the account's original lock is
 *      ROLLING. PERMANENT-original accounts have rebase auto-applied in-place
 *      by Hydrex's RewardsDistributor and do not maintain a separate bucket.
 *
 *      The slot is written only by the portfolio account itself (the receiver
 *      hook on the VE facet); readers must gate on
 *      IHydrexVotingEscrow.ownerOf(stored) == account to guard against stale
 *      pointers if the bucket veNFT is transferred out.
 */
contract HydrexPortfolioFactoryConfig is NFTPortfolioFactoryConfig {
    struct HydrexBucketData {
        mapping(address account => uint256 tokenId) rebaseTokenIds;
    }

    bytes32 private constant HYDREX_BUCKET_STORAGE_POSITION = keccak256("storage.HydrexPortfolioFactoryConfig.RebaseBucket");

    event RebaseBucketSet(address indexed account, uint256 indexed tokenId);

    function _getBucketData() internal pure returns (HydrexBucketData storage data) {
        bytes32 position = HYDREX_BUCKET_STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    modifier onlyPortfolio_() {
        address factory = getPortfolioFactory();
        require(factory != address(0), "Factory not set");
        if (!PortfolioFactory(factory).isPortfolio(msg.sender)) revert NotPortfolio(msg.sender);
        _;
    }

    function setRebaseTokenId(uint256 tokenId) external onlyPortfolio_ {
        _getBucketData().rebaseTokenIds[msg.sender] = tokenId;
        emit RebaseBucketSet(msg.sender, tokenId);
    }

    function getRebaseTokenId(address account) external view returns (uint256) {
        return _getBucketData().rebaseTokenIds[account];
    }
}
