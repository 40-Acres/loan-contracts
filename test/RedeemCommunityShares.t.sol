// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {RedeemCommunityShares} from "../src/CommunityRewards/RedeemCommunityShares.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

interface IAeroMinter {
    function mint(address to, uint256 amount) external;
}


contract RedeemCommunitySharesTest is Test {
    
    RedeemCommunityShares public redeemCommunityShares;

    // grabbed random holders of community shares on Base
    address public user1 = address(0x18EE0115Fd3918d3A75073c98C4a3d9AA0ed2a0B);
    address public user3 = address(0xfA9E221a7aF006531a816E98792a3E4B22A01461);
    address public user2 = address(0xd5b2DaF2285d0FBf2F1c2A20E2866ccf9617E83B);
    

    address public loan;
    address public owner;

    IERC20 public aero;
    IERC20 public shares;

    uint256 public initialAeroBalance = 1000e18;

    function setUp() public {
        uint256 fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);

        loan = address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        owner = IOwnable(loan).owner();

        aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
        shares = IERC20(0x40ac2e1401d6A80e894cA4dbeA7Ca46C6C4f9D3d);

        RedeemCommunityShares _redeemCommunityShares = new RedeemCommunityShares();
        ERC1967Proxy _proxy = new ERC1967Proxy(address(_redeemCommunityShares), "");

        redeemCommunityShares = RedeemCommunityShares(address(_proxy));

        // Initialize the contract with required parameters
        redeemCommunityShares.initialize(
            0x940181a94A35A4569E4529A3CDfB74e38FD98631, // AERO token address
            0x87f18b377e625b62c708D5f6EA96EC193558EFD0, // loan contract address
            0x40ac2e1401d6A80e894cA4dbeA7Ca46C6C4f9D3d  // shares token address
        );

        // Mint AERO tokens to the test contract
        vm.prank(0xeB018363F0a9Af8f91F06FEe6613a751b2A33FE5); //aero minter
        IAeroMinter(0x940181a94A35A4569E4529A3CDfB74e38FD98631).mint(address(this), initialAeroBalance);

        // Transfer AERO tokens to the redeemCommunityShares contract
        aero.transfer(address(redeemCommunityShares), initialAeroBalance);
}

    function test_success_redeem() public {
        
        uint256 userShares = shares.balanceOf(user1);
        uint256 aeroBalance = aero.balanceOf(user1);

        uint256 sharesInOwner = shares.balanceOf(owner);
        vm.startPrank(user1);
        shares.approve(address(redeemCommunityShares), type(uint256).max);
        redeemCommunityShares.redeem(100e18);
        vm.stopPrank();

        assertEq(shares.balanceOf(user1), userShares - 100e18, "User shares should be reduced");
        assertEq(aero.balanceOf(user1), aeroBalance + 100e18, "User aero balance should be increased");
        assertEq(aero.balanceOf(address(redeemCommunityShares)), initialAeroBalance - 100e18, "RedeemCommunityShares should have 100 less AERO");
        assertEq(shares.balanceOf(owner), sharesInOwner + 100e18, "Owner shares should be increased");
    }



    function test_revert_owner_cannot_redeem() public {
        vm.prank(user1);
        shares.transfer(owner, 100e18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RedeemCommunityShares.NotAuthorized.selector));
        redeemCommunityShares.redeem(100e18);
    }

    function test_revert_insufficient_shares() public {
        vm.prank(address(0x2343));
        vm.expectRevert(abi.encodeWithSelector(RedeemCommunityShares.InsufficientShares.selector));
        redeemCommunityShares.redeem(1e18);
    }

    function test_revert_insufficient_payout_token() public {
        vm.prank(address(0x2343));
        vm.expectRevert(abi.encodeWithSelector(RedeemCommunityShares.InsufficientPayoutTokens.selector));
        redeemCommunityShares.redeem(initialAeroBalance + 100e18);
    }

    function test_success_redeem_two_users() public {
        uint256 user1SharesBefore = shares.balanceOf(user1);
        uint256 user1AeroBefore = aero.balanceOf(user1);
        uint256 ownerSharesBefore = shares.balanceOf(owner);

        vm.startPrank(user1);
        shares.approve(address(redeemCommunityShares), 100e18);
        redeemCommunityShares.redeem(100e18);
        vm.stopPrank();

        uint256 user2SharesBefore = shares.balanceOf(user2);
        uint256 user2AeroBefore = aero.balanceOf(user2);

        vm.startPrank(user2);
        shares.approve(address(redeemCommunityShares), 50e18);
        redeemCommunityShares.redeem(50e18);
        vm.stopPrank();

        assertEq(shares.balanceOf(user1), user1SharesBefore - 100e18, "User1 shares incorrect");
        assertEq(aero.balanceOf(user1), user1AeroBefore + 100e18, "User1 AERO incorrect");
        assertEq(shares.balanceOf(user2), user2SharesBefore - 50e18, "User2 shares incorrect");
        assertEq(aero.balanceOf(user2), user2AeroBefore + 50e18, "User2 AERO incorrect");
        assertEq(aero.balanceOf(address(redeemCommunityShares)), initialAeroBalance - 150e18, "Contract AERO balance incorrect");
        assertEq(shares.balanceOf(owner), ownerSharesBefore + 150e18, "Owner shares incorrect");
    }

    function test_revert_zero_redemption() public {
        vm.startPrank(user1);
        shares.approve(address(redeemCommunityShares), 1e18);
        vm.expectRevert(abi.encodeWithSelector(RedeemCommunityShares.ZeroRedemption.selector));
        redeemCommunityShares.redeem(0);
        vm.stopPrank();
    }

}