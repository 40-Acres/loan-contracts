// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IYieldBasisFeeDistributor} from "../interfaces/IYieldBasisFeeDistributor.sol";

/**
 * @title YieldBasisClaimer
 * @notice Keeper contract to batch-claim YieldBasis rewards for portfolio accounts
 * @dev Since FeeDistributor.claim(address) is public, anyone can trigger claims
 *      for any address. This contract batches claims for gas efficiency.
 *
 * Can be called by anyone
 */
contract YieldBasisClaimer {
    IYieldBasisFeeDistributor public immutable feeDistributor;

    event BatchClaimed(address[] accounts, uint256 totalClaimed);
    event ClaimFailed(address account, bytes reason);

    constructor(address _feeDistributor) {
        require(_feeDistributor != address(0), "Invalid fee distributor");
        feeDistributor = IYieldBasisFeeDistributor(_feeDistributor);
    }

    /**
     * @notice Claim rewards for multiple accounts in a single transaction
     * @param accounts Array of portfolio account addresses to claim for
     * @return totalClaimed Total amount claimed across all accounts
     */
    function batchClaim(address[] calldata accounts) external returns (uint256 totalClaimed) {
        for (uint256 i = 0; i < accounts.length; i++) {
            try feeDistributor.claim(accounts[i]) returns (uint256 claimed) {
                totalClaimed += claimed;
            } catch (bytes memory reason) {
                emit ClaimFailed(accounts[i], reason);
            }
        }
        emit BatchClaimed(accounts, totalClaimed);
    }

    /**
     * @notice Claim for a single account
     * @param account The account to claim for
     * @return claimed Amount claimed
     */
    function claimFor(address account) external returns (uint256 claimed) {
        return feeDistributor.claim(account);
    }

    /**
     * @notice Use FeeDistributor's native batch claim (if available)
     * @dev claim_many accepts fixed array of 20 addresses, stops at first zero
     * @param accounts Array of up to 20 addresses (pad with address(0) if fewer)
     */
    function claimMany(address[20] calldata accounts) external returns (bool) {
        return feeDistributor.claim_many(accounts);
    }
}
