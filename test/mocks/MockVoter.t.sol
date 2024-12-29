pragma solidity ^0.8.15;

import { MockVoter } from "./MockVoter.sol";
import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../../src/Loan.sol";

// contract MockVoterTest is Test {
//     MockVoter voter;

//     function setUp() public {
//         voter = new MockVoter(address(0x123), address(0x123), address(0x123));
//     }

//     function testMockVoter() public {
//         assertEq(voter.ve(), address(0x123));
//     }
// }