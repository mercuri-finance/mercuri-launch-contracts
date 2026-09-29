// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4Fixture} from "./V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract V4FixtureTest is V4Fixture {
    function setUp() public { _deployV4(); }

    function test_fixtureDeploys() public view {
        assertGt(address(poolManager).code.length, 0);
        assertGt(address(posm).code.length, 0);
        assertEq(posm.nextTokenId(), 1);
    }

    function test_shimSharesNativeBalance() public {
        address a = makeAddr("a"); address b = makeAddr("b");
        vm.deal(a, 5e18 + 123);
        assertEq(IERC20(USDC).balanceOf(a), 5e6);
        vm.prank(a); IERC20(USDC).transfer(b, 2e6);
        assertEq(a.balance, 3e18 + 123);
        assertEq(b.balance, 2e18);
    }
}
