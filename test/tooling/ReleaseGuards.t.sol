// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GovernedFixture} from "../utils/GovernedFixture.sol";
import {Timelock} from "../../script/Timelock.s.sol";
import {TimelockHistory} from "../../script/utils/TimelockHistory.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Vm} from "forge-std/Vm.sol";

contract TimelockHarness is Timelock {
    function check(System memory s, address proxy, address implementation) external {
        _preflight(
            s, _describe(s, proxy, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes(""))))
        );
    }

    function safeExecute(System memory s, address proxy, address implementation) external {
        safe = true;
        Op memory op =
            _describe(s, proxy, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes(""))));
        op.id = s.timelock.hashOperation(proxy, 0, op.data, bytes32(0), bytes32(0));
        _executeReady(s, op);
    }
}

/// @dev Keeps the observable fee state but can deliberately disable future upgrades
///      or leave its own initializer unlocked. Only used for negative preflight tests.
contract BadFeeImplementation is UUPSUpgradeable, Ownable2StepUpgradeable {
    address public immutable factory;
    address public immutable hook;
    address public immutable graduationManager;
    uint256 public immutable totalOwed;
    uint256 public immutable platformBalance;
    bool private immutable allowUpgrade;

    constructor(FeeManager original, bool lockInitializer, bool allowUpgrade_) {
        factory = address(original.factory());
        hook = original.hook();
        graduationManager = original.graduationManager();
        totalOwed = original.totalOwed();
        platformBalance = original.platformBalance();
        allowUpgrade = allowUpgrade_;
        if (lockInitializer) _disableInitializers();
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {
        require(allowUpgrade, "upgrades disabled");
    }
}

contract ReleaseGuardsTest is GovernedFixture {
    bytes32 constant IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    TimelockHarness harness;

    function setUp() public {
        _deployGoverned();
        harness = new TimelockHarness();
    }

    function system() internal view returns (Timelock.System memory) {
        return Timelock.System(timelock, address(factory), address(feeManager), address(gm), 0, "");
    }

    function test_preflightGoodUpgradesRestoreAllThreeProxies() public {
        address[3] memory proxies = [address(factory), address(feeManager), address(gm)];
        address[3] memory implementations =
            [address(new LaunchFactory()), address(new FeeManager()), address(new GraduationManager())];
        for (uint256 i; i < 3; ++i) {
            bytes32 previous = vm.load(proxies[i], IMPL);
            harness.check(system(), proxies[i], implementations[i]);
            assertEq(vm.load(proxies[i], IMPL), previous, "simulation restored implementation");
            assertEq(LaunchFactory(proxies[i]).owner(), address(timelock));
        }
    }

    function test_preflightRejectsNamespaceDrift() public {
        address implementation = address(new FeeManager());
        bytes memory code = implementation.code;
        bytes32 namespace = 0xc06a3792578c68935c12bd26baefb14bec09a70b6ceafb53cf611fda2f4dc100;
        uint256 patched;
        for (uint256 i; i + 32 <= code.length; ++i) {
            bytes32 word;
            assembly { word := mload(add(add(code, 32), i)) }
            if (word == namespace) {
                code[i + 30] = bytes1(uint8(code[i + 30]) ^ 1);
                ++patched;
            }
        }
        assertGt(patched, 0);
        vm.etch(implementation, code);
        bytes32 previous = vm.load(address(feeManager), IMPL);
        vm.expectRevert("preflight: protected state changed");
        harness.check(system(), address(feeManager), implementation);
        assertEq(vm.load(address(feeManager), IMPL), previous);
    }

    function test_preflightRejectsDisabledFutureUpgrade() public {
        address implementation = address(new BadFeeImplementation(feeManager, true, false));
        vm.expectRevert("preflight: future upgrade disabled");
        harness.check(system(), address(feeManager), implementation);
    }

    function test_preflightRejectsUnlockedInitializer() public {
        address implementation = address(new BadFeeImplementation(feeManager, false, true));
        vm.expectRevert("preflight: implementation initializer unlocked");
        harness.check(system(), address(feeManager), implementation);
    }

    function test_safeExecuteRechecksReadyUpgradeAndRejectsBrokenImplementation() public {
        address implementation = address(new BadFeeImplementation(feeManager, true, false));
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes("")));
        bytes32 id = _schedule(address(feeManager), data);
        vm.warp(block.timestamp + minDelay);
        vm.expectRevert("preflight: future upgrade disabled");
        harness.safeExecute(system(), address(feeManager), implementation);
        assertTrue(timelock.isOperationReady(id));
    }

    function test_safeExecuteGoodUpgradeOnlyPrintsAndRestoresSimulation() public {
        address implementation = address(new FeeManager());
        bytes32 previous = vm.load(address(feeManager), IMPL);
        bytes32 id = _schedule(
            address(feeManager), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes("")))
        );
        vm.warp(block.timestamp + minDelay);
        harness.safeExecute(system(), address(feeManager), implementation);
        assertTrue(timelock.isOperationReady(id));
        assertEq(vm.load(address(feeManager), IMPL), previous);
    }

    function scheduled(bytes32 id, uint256 index) internal pure returns (Vm.EthGetLogs memory entry) {
        entry.topics = new bytes32[](3);
        entry.topics[0] = TimelockController.CallScheduled.selector;
        entry.topics[1] = id;
        entry.topics[2] = bytes32(index);
        entry.data = abi.encode(address(1), uint256(0), bytes("data"), bytes32(0), uint256(60));
        entry.blockNumber = 100;
    }

    function test_cancelAndRescheduleSameBlockIsNotBatch() public pure {
        bytes32 id = bytes32(uint256(123));
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](3);
        logs[0] = scheduled(id, 0);
        logs[1].topics = new bytes32[](2);
        logs[1].topics[0] = TimelockController.Cancelled.selector;
        logs[1].topics[1] = id;
        logs[1].blockNumber = 100;
        logs[2] = scheduled(id, 0);
        TimelockHistory.History memory h = TimelockHistory.parse(logs);
        assertTrue(h.scheduled[0].cancelled);
        assertFalse(h.scheduled[2 - 1].cancelled);
        assertFalse(TimelockHistory.isBatch(h, id));
        (bool found, TimelockHistory.Scheduled memory latest) = TimelockHistory.find(h, id);
        assertTrue(found);
        assertFalse(latest.cancelled);
    }

    function test_realBatchStillRejected() public pure {
        bytes32 id = bytes32(uint256(123));
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = scheduled(id, 0);
        logs[1] = scheduled(id, 1);
        assertTrue(TimelockHistory.isBatch(TimelockHistory.parse(logs), id));
    }

    /// @dev Export freshly deployed local runtime for the independent Python byte verifier.
    function test_exportRuntimeVerificationFixture() public {
        string memory obj = "runtime-fixture";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "poolManager", address(poolManager));
        vm.serializeAddress(obj, "positionManager", address(posm));
        vm.serializeAddress(obj, "usdc", USDC);
        vm.serializeAddress(obj, "feeManager", address(feeManager));
        vm.serializeAddress(obj, "graduationManager", address(gm));
        address[5] memory addresses = [
            address(uint160(uint256(vm.load(address(factory), IMPL)))),
            address(uint160(uint256(vm.load(address(feeManager), IMPL)))),
            address(uint160(uint256(vm.load(address(gm), IMPL)))),
            address(hook),
            address(locker)
        ];
        string[5] memory fields = [
            "factoryImplementation",
            "feeManagerImplementation",
            "graduationManagerImplementation",
            "launchHook",
            "liquidityLocker"
        ];
        string memory json;
        for (uint256 i; i < 5; ++i) {
            vm.serializeAddress(obj, fields[i], addresses[i]);
            json = vm.serializeBytes(obj, string.concat(fields[i], "Code"), addresses[i].code);
        }
        vm.createDir("test-export", true);
        vm.writeJson(json, "test-export/runtime-fixture.json");
    }
}
