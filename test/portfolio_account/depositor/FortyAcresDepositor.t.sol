// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LocalSetup} from "../utils/LocalSetup.sol";
import {FortyAcresDepositor} from "../../../src/accounts/FortyAcresDepositor.sol";
import {IFortyAcresDepositor} from "../../../src/accounts/IFortyAcresDepositor.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";

/**
 * @title FortyAcresDepositorTest
 * @dev The standalone push depositor: the only spender a user approves. Moves
 *      the caller's own asset into the caller's own portfolio (creating it if
 *      needed) at a factory registered with one of the fixed managers. No core
 *      contract is modified; veNFT platforms register collateral on receipt via
 *      the account's onERC721Received.
 */
contract FortyAcresDepositorTest is LocalSetup {
    FortyAcresDepositor internal depositor;

    address internal stranger = address(0x5712A17E);
    address internal newcomer = address(0x4E3C0);
    uint256 internal walletTokenId;

    function setUp() public override {
        super.setUp();

        address[] memory managers = new address[](1);
        managers[0] = address(_portfolioManager);
        depositor = new FortyAcresDepositor(managers);

        // A veNFT in the user's wallet, never approved to the portfolio account.
        walletTokenId = _mockVe.mintTo(_user, int128(uint128(1000e18)));

        _mockUsdc.mint(_vault, 1_000_000e6);
    }

    function _approveAll() internal {
        vm.prank(_user);
        _mockVe.setApprovalForAll(address(depositor), true);
    }

    function _lockedAmount(uint256 tokenId) internal view returns (uint256) {
        return uint256(uint128(IVotingEscrow(_ve).locked(tokenId).amount));
    }

    // ──────────────────────────────────────────────
    // Construction
    // ──────────────────────────────────────────────

    function test_constructor_rejectsEmptyManagers() public {
        address[] memory none = new address[](0);
        vm.expectRevert(IFortyAcresDepositor.NoManagers.selector);
        new FortyAcresDepositor(none);
    }

    function test_constructor_rejectsZeroManager() public {
        address[] memory managers = new address[](2);
        managers[0] = address(_portfolioManager);
        managers[1] = address(0);
        vm.expectRevert(IFortyAcresDepositor.ZeroAddress.selector);
        new FortyAcresDepositor(managers);
    }

    function test_getManagers_isFixed() public view {
        address[] memory managers = depositor.getManagers();
        assertEq(managers.length, 1);
        assertEq(managers[0], address(_portfolioManager));
    }

    // ──────────────────────────────────────────────
    // Factory gating
    // ──────────────────────────────────────────────

    function test_deposit721_revertsForUnregisteredFactory() public {
        _approveAll();
        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(IFortyAcresDepositor.FactoryNotRegistered.selector, stranger));
        depositor.deposit721(stranger, address(_ve), walletTokenId);
    }

    function test_deposit721_revertsForFactoryOfUnknownManager() public {
        // A second, fully separate manager + factory the depositor does not know.
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager otherManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory otherFactory,) = otherManager.deployFactory(keccak256("other"));
        vm.stopPrank();

        assertFalse(depositor.isRegisteredFactory(address(otherFactory)));
        assertTrue(depositor.isRegisteredFactory(address(_portfolioFactory)));

        _approveAll();
        vm.prank(_user);
        vm.expectRevert(
            abi.encodeWithSelector(IFortyAcresDepositor.FactoryNotRegistered.selector, address(otherFactory))
        );
        depositor.deposit721(address(otherFactory), address(_ve), walletTokenId);
    }

    function test_multipleManagers_allFactoriesAccepted() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager otherManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory otherFactory,) = otherManager.deployFactory(keccak256("other"));
        vm.stopPrank();

        address[] memory managers = new address[](2);
        managers[0] = address(_portfolioManager);
        managers[1] = address(otherManager);
        FortyAcresDepositor multi = new FortyAcresDepositor(managers);

        assertTrue(multi.isRegisteredFactory(address(_portfolioFactory)));
        assertTrue(multi.isRegisteredFactory(address(otherFactory)));
        assertFalse(multi.isRegisteredFactory(stranger));
    }

    // ──────────────────────────────────────────────
    // veNFT deposit: the reason this contract exists
    // ──────────────────────────────────────────────

    function test_deposit721_createsAccountWhenMissing_andRegistersCollateral() public {
        // Brand-new user: no portfolio yet. This is exactly the "approve an EOA"
        // situation the depositor removes: the user approves the depositor, not
        // a predicted account.
        uint256 tokenId = _mockVe.mintTo(newcomer, int128(uint128(2000e18)));
        assertEq(_portfolioFactory.portfolioOf(newcomer), address(0), "no account yet");

        vm.startPrank(newcomer);
        _mockVe.setApprovalForAll(address(depositor), true);
        address portfolio = depositor.deposit721(address(_portfolioFactory), address(_ve), tokenId);
        vm.stopPrank();

        assertEq(_portfolioFactory.portfolioOf(newcomer), portfolio, "account created");
        assertTrue(_portfolioManager.isPortfolioRegistered(portfolio), "registered with the manager");
        assertEq(_ve.ownerOf(tokenId), portfolio, "token in the account");
        // VotingEscrowFacet.onERC721Received registered it as collateral on receipt.
        assertEq(CollateralFacet(portfolio).getLockedCollateral(tokenId), _lockedAmount(tokenId));
        assertEq(CollateralFacet(portfolio).getTotalLockedCollateral(), _lockedAmount(tokenId));
    }

    function test_deposit721_existingAccount_operatorApproval() public {
        _approveAll();
        assertFalse(_ve.isApprovedOrOwner(_portfolioAccount, walletTokenId), "account itself never approved");

        vm.prank(_user);
        address portfolio = depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);

        assertEq(portfolio, _portfolioAccount);
        assertEq(_ve.ownerOf(walletTokenId), _portfolioAccount);
        assertEq(CollateralFacet(_portfolioAccount).getLockedCollateral(walletTokenId), _lockedAmount(walletTokenId));
    }

    function test_deposit721_perTokenApproval() public {
        vm.prank(_user);
        _mockVe.approve(address(depositor), walletTokenId);

        vm.prank(_user);
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);

        assertEq(_ve.ownerOf(walletTokenId), _portfolioAccount);
    }

    function test_deposit721_operatorApprovalCoversLaterTokens() public {
        _approveAll();
        uint256 second = _mockVe.mintTo(_user, int128(uint128(700e18)));

        vm.startPrank(_user);
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);
        depositor.deposit721(address(_portfolioFactory), address(_ve), second);
        vm.stopPrank();

        assertEq(_ve.ownerOf(walletTokenId), _portfolioAccount);
        assertEq(_ve.ownerOf(second), _portfolioAccount);
        assertEq(
            CollateralFacet(_portfolioAccount).getTotalLockedCollateral(),
            _lockedAmount(walletTokenId) + _lockedAmount(second)
        );
    }

    function test_deposit721_withoutApproval_reverts() public {
        vm.prank(_user);
        vm.expectRevert(bytes("NotApprovedOrOwner"));
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);
    }

    function test_deposit721_emitsEvent() public {
        _approveAll();
        vm.expectEmit(true, true, true, true, address(depositor));
        emit IFortyAcresDepositor.Deposited721(
            address(_portfolioFactory), _portfolioAccount, _user, address(_ve), walletTokenId
        );
        vm.prank(_user);
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);
    }

    /// `from` is always msg.sender: an approval to the depositor lets nobody
    /// else move the approver's token, not even into the approver's own account.
    function test_deposit721_thirdPartyCannotPushSomeoneElsesToken() public {
        _approveAll();
        vm.prank(stranger);
        vm.expectRevert(bytes("TransferFromIncorrectOwner"));
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);
        assertEq(_ve.ownerOf(walletTokenId), _user);
    }

    function test_deposit721_neverHoldsTheToken() public {
        _approveAll();
        vm.prank(_user);
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);
        assertTrue(_ve.ownerOf(walletTokenId) != address(depositor));
    }

    // ──────────────────────────────────────────────
    // Then borrow: the usual multicall, token already in the account
    // ──────────────────────────────────────────────

    function test_depositThenBorrow() public {
        _approveAll();
        vm.prank(_user);
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);

        uint256 before = _mockUsdc.balanceOf(_user);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, uint256(100e6));
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        vm.prank(_user);
        _portfolioManager.multicall(calldatas, factories);

        assertGt(_mockUsdc.balanceOf(_user), before);
        assertEq(CollateralFacet(_portfolioAccount).getTotalDebt(), 100e6);
    }

    /// Platforms whose account uses the plain ERC721ReceiverFacet do not
    /// auto-register; an explicit addCollateral still works because the token
    /// is already in the account (no approval to the account needed).
    function test_depositThenExplicitAddCollateral_isIdempotent() public {
        _approveAll();
        vm.prank(_user);
        depositor.deposit721(address(_portfolioFactory), address(_ve), walletTokenId);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, walletTokenId);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        vm.prank(_user);
        _portfolioManager.multicall(calldatas, factories);

        assertEq(CollateralFacet(_portfolioAccount).getLockedCollateral(walletTokenId), _lockedAmount(walletTokenId));
    }

    // ──────────────────────────────────────────────
    // ERC20 deposit
    // ──────────────────────────────────────────────

    function test_deposit20_movesTokensIntoOwnPortfolio() public {
        _mockAero.mint(_user, 500e18);
        vm.startPrank(_user);
        _mockAero.approve(address(depositor), 500e18);

        vm.expectEmit(true, true, true, true, address(depositor));
        emit IFortyAcresDepositor.Deposited20(
            address(_portfolioFactory), _portfolioAccount, _user, address(_mockAero), 200e18
        );
        address portfolio = depositor.deposit20(address(_portfolioFactory), address(_mockAero), 200e18);
        vm.stopPrank();

        assertEq(portfolio, _portfolioAccount);
        assertEq(_mockAero.balanceOf(_portfolioAccount), 200e18);
        assertEq(_mockAero.balanceOf(_user), 300e18);
        assertEq(_mockAero.balanceOf(address(depositor)), 0, "never holds anything");
    }

    function test_deposit20_createsAccountWhenMissing() public {
        _mockUsdc.mint(newcomer, 50e6);
        vm.startPrank(newcomer);
        _mockUsdc.approve(address(depositor), 50e6);
        address portfolio = depositor.deposit20(address(_portfolioFactory), _usdc, 50e6);
        vm.stopPrank();

        assertEq(_portfolioFactory.portfolioOf(newcomer), portfolio);
        assertEq(_mockUsdc.balanceOf(portfolio), 50e6);
    }

    function test_deposit20_withoutAllowance_reverts() public {
        _mockAero.mint(_user, 1e18);
        vm.prank(_user);
        vm.expectRevert();
        depositor.deposit20(address(_portfolioFactory), address(_mockAero), 1e18);
    }

    function test_deposit20_revertsForUnregisteredFactory() public {
        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(IFortyAcresDepositor.FactoryNotRegistered.selector, stranger));
        depositor.deposit20(stranger, _usdc, 1);
    }

    // ──────────────────────────────────────────────
    // Views used by the frontend
    // ──────────────────────────────────────────────

    function test_portfolioOf() public view {
        assertEq(depositor.portfolioOf(address(_portfolioFactory), _user), _portfolioAccount);
        assertEq(depositor.portfolioOf(address(_portfolioFactory), newcomer), address(0));
    }

    function test_isApproved721_reflectsOperatorAndPerTokenApproval() public {
        assertFalse(depositor.isApproved721(address(_ve), _user, walletTokenId));

        vm.prank(_user);
        _mockVe.approve(address(depositor), walletTokenId);
        assertTrue(depositor.isApproved721(address(_ve), _user, walletTokenId), "per-token");

        vm.prank(_user);
        _mockVe.approve(address(0), walletTokenId);
        assertFalse(depositor.isApproved721(address(_ve), _user, walletTokenId));

        _approveAll();
        assertTrue(depositor.isApproved721(address(_ve), _user, walletTokenId), "operator");
    }

    function test_isApproved721_nonErc721TokenIsFalseNotRevert() public view {
        assertFalse(depositor.isApproved721(_usdc, _user, 1));
    }

    function test_allowance20() public {
        assertEq(depositor.allowance20(_usdc, _user), 0);
        vm.prank(_user);
        _mockUsdc.approve(address(depositor), 42e6);
        assertEq(depositor.allowance20(_usdc, _user), 42e6);
    }
}
