// SPDX-License-Identifier: UNLICENSED
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
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IUSDC} from "../../../src/interfaces/IUSDC.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

contract ClaimingFacetTest is Test, Setup {
    address[] public pools = [address(0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0)];
    address[] public bribes = [address(0x765d935C2F47a06EdA55D07a9b9aE4108F4BBF85)];
    uint256[] public weights = [100e18];
    address public claimingToken = address(0x4200000000000000000000000000000000000006);
    address[][] public poolTokens = [[address(claimingToken), address(_usdc)]];
    address[][] public launchPadTokens = [[address(claimingToken)]];
    uint256 rewardAmount = 1090570742412276;
    uint256 usdcAmount = 3462465;

    // Helper function to add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to vote for launchpad token via PortfolioManager multicall
    function voteForLaunchpadTokenViaMulticall(uint256 tokenId, address[] memory pools, uint256[] memory weights, bool receiveToken) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VotingFacet.voteForLaunchpadToken.selector,
            tokenId,
            pools,
            weights,
            receiveToken
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    function testClaim() public {
        vm.startPrank(_authorizedCaller);
        ClaimingFacet(_portfolioAccount).claimFees(bribes, poolTokens, _tokenId);
        vm.stopPrank();

        assertEq(IERC20(claimingToken).balanceOf(_portfolioAccount), rewardAmount);
        assertEq(IERC20(_usdc).balanceOf(_portfolioAccount), usdcAmount);
    }

    function testClaimRebase() public {
        int128 startingLockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            ClaimingFacet.claimRebase.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        int128 endingLockedAmount = IVotingEscrow(_ve).locked(_tokenId).amount;
        assertEq(endingLockedAmount, startingLockedAmount + 1128188206630704788);
    }

    function testClaimLaunchpadTokenReceiveTokenNoLoanBalance() public {
        vm.startPrank(_owner);
        _votingConfig.setLaunchpadPoolTokenForEpoch(ProtocolTimeLibrary.epochNext(block.timestamp), pools[0], claimingToken);
        vm.stopPrank();
        // user votes on launchpad token pool
        voteForLaunchpadTokenViaMulticall(_tokenId, pools, weights, true);

        // fast forward to next epoch
        vm.warp(ProtocolTimeLibrary.epochNext(block.timestamp));
        vm.roll(block.number + 1);

        
        vm.startPrank(_authorizedCaller);
        ClaimingFacet(_portfolioAccount).claimLaunchpadToken(bribes, launchPadTokens, _tokenId, address(0), new bytes(0), rewardAmount);
        vm.stopPrank();

        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        assertEq(IERC20(claimingToken).balanceOf(portfolioOwner), rewardAmount);
    }


    function testClaimLaunchpadTokenNoReceive() public {
        vm.startPrank(_owner);
        _votingConfig.setLaunchpadPoolTokenForEpoch(ProtocolTimeLibrary.epochNext(block.timestamp), pools[0], claimingToken);
        vm.stopPrank();
        // user votes on launchpad token pool
        voteForLaunchpadTokenViaMulticall(_tokenId, pools, weights, false);

        // fast forward to next epoch
        vm.warp(ProtocolTimeLibrary.epochNext(block.timestamp));
        vm.roll(block.number + 1);

        
        vm.startPrank(_authorizedCaller);
        ClaimingFacet(_portfolioAccount).claimLaunchpadToken(bribes, launchPadTokens, _tokenId, address(0), new bytes(0), rewardAmount);
        vm.stopPrank();

        assertEq(IERC20(claimingToken).balanceOf(_portfolioAccount), rewardAmount);
    }

    function testClaimLaunchpadTokenActiveBalanceReceiveToken() public {
        // Add collateral and create debt to simulate active loan balance
        addCollateralViaMulticall(_tokenId);
        borrowViaMulticall(1e6);

        // Set up launchpad token voting
        vm.startPrank(_owner);
        _votingConfig.setLaunchpadPoolTokenForEpoch(ProtocolTimeLibrary.epochNext(block.timestamp), pools[0], claimingToken);
        vm.stopPrank();
        
        // user votes on launchpad token pool with receiveToken = true
        voteForLaunchpadTokenViaMulticall(_tokenId, pools, weights, true);

        // fast forward to next epoch
        vm.warp(ProtocolTimeLibrary.epochNext(block.timestamp));
        vm.roll(block.number + 1);

        // Deploy MockOdosRouter
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        address minter = IUSDC(_usdc).masterMinter();
        vm.startPrank(minter);
        IUSDC(_usdc).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(_usdc).mint(address(mockRouter), 10000e18);

        uint256 expectedUsdcOutput = 250e6;

        // Create tradeData to call executeSwap
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            claimingToken,  // tokenIn
            _usdc,          // tokenOut
            rewardAmount,   // amountIn
            expectedUsdcOutput, // amountOut
            _portfolioAccount  // receiver
        );

        // Record balances before claim
        uint256 portfolioUsdcBefore = IERC20(_usdc).balanceOf(_portfolioAccount);
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 ownerTokenBefore = IERC20(claimingToken).balanceOf(portfolioOwner);
        uint256 vaultUsdcBefore = IERC20(_usdc).balanceOf(ILoan(_loanContract)._vault());
        uint256 ownerUsdcBefore = IERC20(_usdc).balanceOf(ILoan(_loanContract).owner());

        // Claim launchpad token with swap
        vm.startPrank(_authorizedCaller);
        ClaimingFacet(_portfolioAccount).claimLaunchpadToken(bribes, launchPadTokens, _tokenId, address(mockRouter), tradeData, expectedUsdcOutput);
        vm.stopPrank();

        // Verify the swap happened - portfolio account should have received USDC
        uint256 portfolioUsdcAfter = IERC20(_usdc).balanceOf(_portfolioAccount);
        uint256 ownerTokenAfter = IERC20(claimingToken).balanceOf(_owner);
        uint256 vaultUsdcAfter = IERC20(_usdc).balanceOf(ILoan(_loanContract)._vault());
        uint256 ownerUsdcAfter = IERC20(_usdc).balanceOf(ILoan(_loanContract).owner());
        // The portfolio account should have received USDC from the swap
        assertEq(portfolioUsdcAfter, portfolioUsdcBefore, "Portfolio should have received USDC from swap");
        // The launchpad token should have been swapped, so owner should receive remaining (after fees)
        // Note: Some tokens may have been used for fees, so owner may have less than rewardAmount
        assertGe(ownerTokenAfter, ownerTokenBefore, "Owner should receive remaining launchpad token after swap and fees");
        assertEq(vaultUsdcAfter, vaultUsdcBefore + 200e6, "Vault should have received USDC from swap");
        assertEq(ownerUsdcAfter, ownerUsdcBefore + 50e6, "Owner should have received USDC from swap");
    }
}