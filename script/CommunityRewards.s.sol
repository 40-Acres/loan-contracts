// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// import {Script, console} from "forge-std/Script.sol";
// import {Loan} from "../src/LoanV2.sol";
// import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
// import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// contract CommunityRewards is Script {

//     function run() external  {
//         vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
//         CommunityRewards _communityRewards = new CommunityRewards();
//         vm.stopBroadcast();
//         vm.startBroadcast(vm.envUint("VANITY_PRIVATE_KEY_1"));
//         ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
//         votingEscrow.approve(address(_proxy), tokenId);
//         CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 2500e18, tokenId, 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
//         vm.stopBroadcast();
//     }

//     function upgradeLoan(address _proxy) public {
//         Loan loan = new Loan();
//         Loan proxy = Loan(payable(_proxy));
//         proxy.upgradeToAndCall(address(loan), new bytes(0));
//     }
// }