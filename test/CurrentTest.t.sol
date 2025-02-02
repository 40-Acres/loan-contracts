// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ProtocolTimeLibrary } from "src/libraries/ProtocolTimeLibrary.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import { console} from "forge-std/console.sol";


contract CurrentTest is Test {
    uint256 fork;

    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;
    
    Loan public loan =
        Loan(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));

    function testRequestLoan() public {


        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);

        uint256 _tokenId = 65204;
        // uint256 amount = 1e6;

        address owner = address(loan.owner());
        vm.startPrank(owner);
        Loan loanV2 = new Loan();
        Vault vault = Vault(loan._vault());
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();

        address _user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(_user);
        uint256[] memory _weights = new uint256[](1);
        _weights[0] = 100e18;
        IERC721(address(votingEscrow)).approve(0x87f18b377e625b62c708D5f6EA96EC193558EFD0, _tokenId);
        vm.stopPrank();
        vm.startPrank(owner);
        Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).setDefaultPools(pool, _weights);
        vm.stopPrank();
        vm.prank(_user);
        Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.DoNothing);
        console.log(Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0)._defaultPoolChangeTime());
    }
}