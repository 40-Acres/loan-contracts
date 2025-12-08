// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IXLoan} from "../../interfaces/IXLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccountConfigStorage} from "../../storage/AccountConfigStorage.sol";
import {IXVoter} from "../../interfaces/IXVoter.sol";

/**
 * @title XPharaohLegacyClaimFacet
 * @notice Minimal facet to claim and process legacy rewards.
 */
contract XPharaohLegacyClaimFacet {
    AccountConfigStorage public immutable _accountConfigStorage;
    address public immutable _voter = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7;
    address public constant _odosRouter = 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC;

    constructor(address accountConfigStorage) {
        require(accountConfigStorage != address(0));
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
    }

    /**
     * @notice Claim legacy incentives via XVoter and process outputs through Odos.
     * @dev Excess preferred token and vault asset are forwarded to the caller (loan contract).
     */
    function xPharProcessLegacyRewards(
        address[] calldata feeDistributors,
        address[][] calldata tokens,
        bytes calldata tradeData
    ) public onlyApprovedContract(msg.sender) {
        address vaultAsset = address(IXLoan(msg.sender)._vaultAsset());
        uint256 beginningAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        uint256 beginningPreferredTokenBalance;
        address preferredToken = IXLoan(msg.sender).getPreferredToken(address(this));
        if (preferredToken != address(0)) {
            beginningPreferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
        }

        uint256[][] memory tokenBalances = new uint256[][](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenBalances[i] = new uint256[](tokens[i].length);
            for (uint256 j = 0; j < tokens[i].length; j++) {
                IERC20 token = IERC20(tokens[i][j]);
                tokenBalances[i][j] = token.balanceOf(address(this));
                token.approve(_odosRouter, type(uint256).max);
            }
        }

        IXVoter(_voter).claimLegacyIncentives(address(this), feeDistributors, tokens);
        if (tradeData.length == 0) {
            revert(); // No trade data provided, cannot proceed with claiming rewards
        }

        (bool success,) = _odosRouter.call{value: 0}(tradeData);
        require(success);

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
                IERC20 token = IERC20(tokens[i][j]);
                uint256 tokenBalance = token.balanceOf(address(this));
                require(tokenBalance >= tokenBalances[i][j]);
                if (token.allowance(address(this), _odosRouter) != 0) {
                    token.approve(_odosRouter, 0);
                }
            }
        }

        if (preferredToken != address(0)) {
            uint256 preferredTokenBalance = IERC20(preferredToken).balanceOf(address(this));
            if (preferredTokenBalance > beginningPreferredTokenBalance) {
                IERC20(preferredToken).transfer(
                    address(msg.sender),
                    preferredTokenBalance - beginningPreferredTokenBalance
                );
            }
        }

        uint256 endingAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        if (endingAssetBalance > beginningAssetBalance) {
            IERC20(vaultAsset).transfer(address(msg.sender), endingAssetBalance - beginningAssetBalance);
        }
    }

    modifier onlyApprovedContract(address destination) {
        require(_accountConfigStorage.isApprovedContract(destination));
        _;
    }
}