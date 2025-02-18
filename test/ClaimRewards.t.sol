// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolTimeLibrary} from "src/libraries/ProtocolTimeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import { console} from "forge-std/console.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(
        address minter,
        uint256 minterAllowedAmount
    ) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

contract ClaimRewardsTest is Test {
    uint256 fork;

    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow =
        IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan =
        Loan(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
    address owner;
    address user;
    uint256 tokenId = 68510;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(26007320);
    }

    function testClaimRewards() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(26007320);
        owner = loan.owner();
        vm.startPrank(owner);
        Loan loanV2 = new Loan();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();


        loan.voteOnDefaultPool(tokenId);
        (uint256 borrower,, address[] memory pools) = loan.getLoanDetails(271);
        address tokenOwner = votingEscrow.ownerOf(tokenId);
        console.log("tokenOwner", tokenOwner);
        console.log("borrower", borrower);  
        console.log("pools", pools.length);
        // assertEq(pools[0], pool[0], "should be in pool");
        // console.log("pool", pools[0]);

        

        uint256 ownerUsdBalance = usdc.balanceOf(loan.owner());
        console.log("owner", ownerUsdBalance / 1e6);
        uint256[] memory _tokenIds = new uint256[](7);
        _tokenIds[0] = 271;
        // _tokenIds[1] = 37681;
        // _tokenIds[2] = 10131;
        // _tokenIds[3] = 40579;
        // _tokenIds[4] =  65204;
        // _tokenIds[5]  = 69712;
        // _tokenIds[6] = 64196;
        // _tokenIds[7] = 64196;
        // _tokenIds[8] = 68510;
        // _tokenIds[9] = 67936;
        // _tokenIds[10] = 64578;
        // _tokenIds[11] = 69655;
        // _tokenIds[12] = 64279;
        // vm.startPrank(owner);
        // loan.claimRewardsMultiple(_tokenIds);
        for(uint256 i = 0; i < _tokenIds.length; i++) {
            loan.claimRewards(_tokenIds[i]);
        }
        ownerUsdBalance = usdc.balanceOf(loan._vault());
        console.log("vault", ownerUsdBalance / 1e6);
    }
}
