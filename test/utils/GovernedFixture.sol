// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

/// @dev Deploys the whole system exactly like `LaunchFixture`, except the owner of all three proxies is a real
///      OpenZeppelin `TimelockController` rather than the test contract itself (spec section 3): proposer,
///      executor and canceller are all `admin`; the timelock has no separate admin role (`address(0)`, i.e. it
///      administers itself); the guardian is a distinct address, unrelated to the timelock.
abstract contract GovernedFixture is LaunchFixture {
    TimelockController internal timelock;
    address internal admin = makeAddr("admin");
    /// @dev 60 s in tests, per the brief; a test may set this to something else before `_deployGoverned`.
    uint256 internal minDelay = 60;

    function _deployGoverned() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        timelock = new TimelockController(minDelay, proposers, executors, address(0));

        // `LaunchFixture._deploySystem` reads `owner` at call time, so overriding it here (before deploying)
        // makes the timelock, not this test contract, the owner of all three proxies.
        owner = address(timelock);
        _deploySystem();
    }

    /// @dev Schedules `target.call(data)` with a zero predecessor and zero salt, at exactly `minDelay`. Returns
    ///      the operation id so a test can inspect its state or `cancel` it.
    function _schedule(address target, bytes memory data) internal returns (bytes32 id) {
        id = timelock.hashOperation(target, 0, data, bytes32(0), bytes32(0));
        vm.prank(admin);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), minDelay);
    }

    /// @dev Schedules AND executes: warps exactly `minDelay` forward (the real "wait" the runbook performs on
    ///      testnet), then executes as `admin`. Returns the operation id.
    function _execute(address target, bytes memory data) internal returns (bytes32 id) {
        id = _schedule(target, data);
        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }
}
