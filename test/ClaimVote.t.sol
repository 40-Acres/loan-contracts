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
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

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


contract ClaimVoteTest is Test {
    uint256 fork;

    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow =
        IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan =
        Loan(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
    address owner;
    address user;
    uint256 tokenId = 64578;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(26384470);
        vm.rollFork(26384470);
        owner = Ownable2StepUpgradeable(address(loan)).owner();
        user = votingEscrow.ownerOf(tokenId);

        vm.startPrank(owner);
        Loan loanV2 = new Loan();
        vault = Vault(loan._vault());
        loan.upgradeToAndCall(address(loanV2), new bytes(0));

        loan.setMultiplier(100000000000);
        vm.stopPrank();

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        vm.stopPrank();
    }



    function testDefaultPools() public { 
        address pool = loan._defaultPools(0);
        assertTrue(pool != address(0), "default pool should not be 0");

        assertTrue(loan._defaultWeights(0) > 0, "default pool weight should be greater than 0");
        
        uint256 defaultPoolChangeTime = loan._defaultPoolChangeTime();
        assertTrue(defaultPoolChangeTime > 0, "default pool change time should be greater than 0");

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        address[] memory pools = new address[](2);
        pools[0] = address(0x52f38A65DAb3Cf23478cc567110BEC90162aB832);
        pools[1] = address(0x52F38a65daB3cF23478Cc567110bEc90162AB833);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 50e18;
        weights[1] = 50e18;
        loan.setDefaultPools(pools, weights);
        vm.stopPrank();

        assertTrue(loan._defaultPools(0) == pools[0], "default pool should be updated");
        assertTrue(loan._defaultPools(1) == pools[1], "default pool should be updated");
        assertTrue(loan._defaultWeights(0) == weights[0], "default pool weight should be updated");
        assertTrue(loan._defaultWeights(1) == weights[1], "default pool weight should be updated");
        assertTrue(loan._defaultPoolChangeTime() >= defaultPoolChangeTime, "default pool change time should be updated");
        

    }

    function testLoanWeight() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(26384470);
        owner = Ownable2StepUpgradeable(address(loan)).owner();
        user = votingEscrow.ownerOf(tokenId);

        vm.startPrank(owner);
        Loan loanV2 = new Loan();
        vault = Vault(loan._vault());
        loan.upgradeToAndCall(address(loanV2), new bytes(0));

        loan.setMultiplier(100000000000);
        vm.stopPrank();

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        vm.stopPrank();
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 25309;
        tokenIds[1] = 271;
        tokenIds[2] = 10131;
        loan.claimRewards(tokenIds[0]);
        uint256 loanWeight = loan.getTotalWeight();
        console.log("loan weight", loanWeight);
        loan.claimRewards(tokenIds[1]);
        loanWeight = loan.getTotalWeight();
        console.log("loan weight", loanWeight);
        loan.claimRewards(tokenIds[2]);
        loanWeight = loan.getTotalWeight();
        console.log("loan weight", loanWeight);
        assertTrue(loanWeight >= 0, "loan weight should be greater than 0");
    }
}