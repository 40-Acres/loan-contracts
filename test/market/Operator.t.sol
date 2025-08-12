// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../utils/DiamondMarketTestBase.t.sol";
import {IMarketOperatorFacet} from "src/interfaces/IMarketOperatorFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {ILoan} from "src/interfaces/ILoan.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";

interface IUSDC { function approve(address, uint256) external returns (bool); function configureMinter(address, uint256) external; function mint(address, uint256) external; }

contract OperatorTest is DiamondMarketTestBase {
    Loan public loan;
    Vault vault;
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 usdcErc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address user;
    address operator;
    uint256 tokenId;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 24353746);
        operator = vm.addr(0xB0B);

        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();
        _deployDiamondAndFacets();
        IMarketConfigFacet(diamond).initMarket(address(loan), address(votingEscrow), 250, address(this), address(usdc));
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), true);

        tokenId = 349;
        user = votingEscrow.ownerOf(tokenId);
        vm.assume(user != address(0));
    }

    function test_operator_can_update_and_cancel() public {
        // Move token into loan custody to allow loan listing
        vm.startPrank(user);
        IVotingEscrow(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, 1000e6, address(usdc), 0);
        IMarketOperatorFacet(diamond).setOperatorApproval(operator, true);
        vm.stopPrank();

        vm.prank(operator);
        IMarketListingsLoanFacet(diamond).updateLoanListing(tokenId, 1500e6, address(usdc), 0);
        (, uint256 price,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(price, 1500e6);

        vm.prank(operator);
        IMarketListingsLoanFacet(diamond).cancelLoanListing(tokenId);
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
    }
}


