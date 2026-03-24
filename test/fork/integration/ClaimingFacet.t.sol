// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {PortfolioFactoryDeploy} from "../../../script/portfolio_account/PortfolioFactoryDeploy.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {Setup} from "../portfolio_account/utils/Setup.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IUSDC} from "../../../src/interfaces/IUSDC.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";

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
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseCollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseLendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper function to vote for launchpad token via PortfolioManager multicall
    function voteForLaunchpadTokenViaMulticall(uint256 tokenId, address[] memory pools, uint256[] memory weights, bool receiveToken) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VotingFacet.voteForLaunchpadToken.selector,
            tokenId,
            pools,
            weights,
            receiveToken
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
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
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            ClaimingFacet.claimRebase.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
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
        SwapMod.RouteParams memory noSwap;
        noSwap.minimumOutputAmount = rewardAmount;
        ClaimingFacet(_portfolioAccount).claimLaunchpadToken(bribes, launchPadTokens, _tokenId, noSwap);
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
        SwapMod.RouteParams memory noSwap;
        noSwap.minimumOutputAmount = rewardAmount;
        ClaimingFacet(_portfolioAccount).claimLaunchpadToken(bribes, launchPadTokens, _tokenId, noSwap);
        vm.stopPrank();

        assertEq(IERC20(claimingToken).balanceOf(_portfolioAccount), rewardAmount);
    }

    function testClaimLaunchpadTokenActiveBalanceReceiveToken() public {
        // Add collateral and create debt to simulate active loan balance
        addCollateralViaMulticall(_tokenId);
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        uint256 borrowAmount = 1e6;
        address loanContract = _portfolioFactoryConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_usdc), vault, 10000e6);

        // get max loan
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = CollateralFacet(_portfolioAccount).getMaxLoan();
        console.log("maxLoan", maxLoan);
        console.log("maxLoanIgnoreSupply", maxLoanIgnoreSupply);
        require(borrowAmount <= maxLoan, "Borrow amount exceeds max loan");
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);


        // Deploy MockOdosRouter
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        address minter = IUSDC(_usdc).masterMinter();
        vm.startPrank(minter);
        IUSDC(_usdc).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(_usdc).mint(address(mockRouter), 10000e18);


        // Set up launchpad token voting
        vm.startPrank(_owner);
        _votingConfig.setLaunchpadPoolTokenForEpoch(ProtocolTimeLibrary.epochNext(block.timestamp), pools[0], claimingToken);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();
        
        // user votes on launchpad token pool with receiveToken = true
        voteForLaunchpadTokenViaMulticall(_tokenId, pools, weights, true);

        // fast forward to next epoch
        vm.warp(ProtocolTimeLibrary.epochNext(block.timestamp));
        vm.roll(block.number + 1);

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
        SwapMod.RouteParams memory swapParams = SwapMod.RouteParams({
            swapConfig: address(0),
            swapTarget: address(mockRouter),
            swapData: tradeData,
            inputToken: address(0),
            inputAmount: 0,
            outputToken: address(0),
            minimumOutputAmount: expectedUsdcOutput
        });
        ClaimingFacet(_portfolioAccount).claimLaunchpadToken(bribes, launchPadTokens, _tokenId, swapParams);
        vm.stopPrank();

        // Fee rates: lenderPremium=2000 (20%), treasuryFee=500 (5%)
        // With 250e6 output:
        //   treasuryFee    = 250e6 * 500  / 10000 = 12.5e6
        //   lenderPremium  = 250e6 * 2000 / 10000 = 50e6
        //   borrowerAmount = 250e6 - 12.5e6 - 50e6 = 187.5e6
        //   debt = 1e6, so 1e6 goes to vault as debt repayment, 186.5e6 excess → owner
        uint256 expectedTreasuryFee = (expectedUsdcOutput * 500) / 10000;    // 12.5e6
        uint256 expectedLenderPremium = (expectedUsdcOutput * 2000) / 10000; // 50e6
        uint256 expectedBorrowerAmount = expectedUsdcOutput - expectedTreasuryFee - expectedLenderPremium; // 187.5e6
        uint256 expectedDebtRepaid = borrowAmount; // 1e6 (capped at actual debt)
        uint256 expectedExcessToOwner = expectedBorrowerAmount - expectedDebtRepaid; // 186.5e6

        uint256 portfolioUsdcAfter = IERC20(_usdc).balanceOf(_portfolioAccount);
        uint256 ownerTokenAfter = IERC20(claimingToken).balanceOf(_owner);
        uint256 vaultUsdcAfter = IERC20(_usdc).balanceOf(ILoan(_loanContract)._vault());
        uint256 ownerUsdcAfter = IERC20(_usdc).balanceOf(ILoan(_loanContract).owner());

        // Portfolio should have no leftover USDC (all distributed)
        assertEq(portfolioUsdcAfter, portfolioUsdcBefore, "Portfolio should not retain USDC");
        // Owner should receive remaining launchpad tokens
        assertGe(ownerTokenAfter, ownerTokenBefore, "Owner should receive remaining launchpad token");
        // Treasury receives BPS-based fee only (not inflated share)
        assertEq(ownerUsdcAfter, ownerUsdcBefore + expectedTreasuryFee, "Treasury should receive BPS-based fee");
        // Vault receives lender premium + actual debt repayment (not the full borrower amount)
        assertEq(vaultUsdcAfter, vaultUsdcBefore + expectedLenderPremium + expectedDebtRepaid, "Vault should receive lender premium + debt repayment");
        // Portfolio owner receives excess USDC beyond debt
        uint256 ownerUsdcTotal = IERC20(_usdc).balanceOf(portfolioOwner);
        // Owner got: borrow proceeds (1e6 - origination fee) + excess from launchpad claim
        assertGt(ownerUsdcTotal, expectedExcessToOwner, "Owner should receive excess USDC from borrower share");
    }
}