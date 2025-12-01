pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {PortfolioFactoryDeploy} from "../../../script/portfolio_account/PortfolioFactoryDeploy.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {Setup} from "../utils/Setup.sol";

contract ClaimingFacetTest is Test, Setup {

    function testClaim() public {
        address[] memory bribes = new address[](1);
        bribes[0] = address(0x765d935C2F47a06EdA55D07a9b9aE4108F4BBF85);

        address[][] memory bribesData = new address[][](1);
        bribesData[0] = new address[](2);
        bribesData[0][0] = address(_usdc);
        bribesData[0][1] = address(0x4200000000000000000000000000000000000006);

        ClaimingFacet(_portfolioAccount).claimFees(bribes, bribesData, _tokenId);

        assertEq(IERC20(0x4200000000000000000000000000000000000006).balanceOf(_portfolioAccount), 1090570742412276);
        assertEq(IERC20(_usdc).balanceOf(_portfolioAccount), 3462465
);
    }

    function testClaimRebase() public {
        int128 startingLockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        ClaimingFacet(_portfolioAccount).claimRebase(_tokenId);
        int128 endingLockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(endingLockedAmount, startingLockedAmount + 1128188206630704788);
    }
}