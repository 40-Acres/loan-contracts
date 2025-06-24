// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import { Vault } from "src/VaultV2.sol";
import { IVotingEscrow } from "src/interfaces/IVotingEscrow.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Loan } from "src/LoanV2.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";



interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);

}

contract VaultTest is Test {
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    address aero = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    // deployed contracts
    uint256 fork;
    Vault vault;
    Loan public loan =
        Loan(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
    address owner = 0x97BE22DBb49C88451fBd1099F59EED963d9d8A12;
    address user;
    uint256 tokenId = 64196;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(25713608);
        ERC4626Upgradeable vaultImplementation = new Vault();
        ERC1967Proxy _vault = new ERC1967Proxy(address(vaultImplementation), "");
        vault = Vault(payable(_vault));    
        Vault(address(_vault)).initialize(address(usdc), address(loan), "", "");

        vm.prank(address(aero));
        IERC20(aero).transfer(address(this), 100e18);
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(this), 100e6);
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testDepositWithdrawal() public {
        uint256 amount = 100e6;
        usdc.approve(address(vault), amount);
        console.log(usdc.balanceOf(address(this)));
        vault.deposit(amount, address(this));
        assertEq(vault.totalAssets(), amount);
        vault.withdraw(amount, address(this), address(this));
        assertEq(vault.totalAssets(), 0);
    }

    function testDepositWithdrawalPlus() public {
        uint256 amount = 100e6;
        usdc.approve(address(vault), amount);
        console.log(usdc.transfer(address(this), amount));
        vault.deposit(amount, address(this));
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(vault), 50e6);
        vm.stopPrank();

        assertEq(ERC4626Upgradeable(vault).maxWithdraw(address(this)), 149999999);
        assertEq(vault.totalAssets(), 150e6);
        vault.withdraw(ERC4626Upgradeable(vault).maxWithdraw(address(this)), address(this), address(this));
        assertEq(vault.totalAssets(), 1);
    }

    function testUpgrade() public {
        vm.startPrank(owner);
        vault.upgradeToAndCall(
            address(new Vault()),
            ""
        );
        vm.stopPrank();
        assertTrue(true);
    }
}


