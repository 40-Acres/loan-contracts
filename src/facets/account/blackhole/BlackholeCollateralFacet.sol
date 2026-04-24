// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CollateralFacet} from "../collateral/CollateralFacet.sol";
import {IVoter} from "../../../Blackhole/interfaces/IVoter.sol";

/**
 * @title BlackholeCollateralFacet
 */
contract BlackholeCollateralFacet is CollateralFacet {
    IVoter public immutable _voter;

    constructor(address portfolioFactory, address votingEscrow, address voter)
        CollateralFacet(portfolioFactory, votingEscrow)
    {
        require(voter != address(0));
        _voter = IVoter(voter);
    }

    function _removeLockedCollateral(uint256 tokenId, address config, address ve) internal override {
        try _voter.reset(tokenId) {} catch {}
        super._removeLockedCollateral(tokenId, config, ve);
    }
}
