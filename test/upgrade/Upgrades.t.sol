// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernedFixture} from "../utils/GovernedFixture.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {IFeeManager} from "../../src/interfaces/IFeeManager.sol";
import {LaunchFactoryV2Mock} from "../utils/upgrade/LaunchFactoryV2Mock.sol";
import {FeeManagerV2Mock} from "../utils/upgrade/FeeManagerV2Mock.sol";
import {GraduationManagerV2Mock} from "../utils/upgrade/GraduationManagerV2Mock.sol";
import {BondingCurveV2Mock} from "../utils/upgrade/BondingCurveV2Mock.sol";

/// @dev Minimal view of `Ownable2StepUpgradeable`'s external surface, used to run the SAME two-step-ownership
///      assertion against all three proxies without depending on each contract's own concrete type.
interface IOwnable2StepMinimal {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @dev Upgrade, timelock and governance tests (spec section 7), run against the SAME deployment order as
///      production (`GovernedFixture`/`LaunchFixture`), with a real `TimelockController` as the owner of all
///      three proxies.
contract UpgradesTest is GovernedFixture {
    function setUp() public {
        _deployGoverned();
    }

    // ================================================================== factory

    function test_factoryUpgradePreservesOldCurvesAndAppliesNewCurveOnlyToFutureLaunches() public {
        (LaunchToken token1, BondingCurve curve1) = _create(bytes32(uint256(1)));
        bytes32 codehashBefore = address(curve1).codehash;

        address newImpl = address(new LaunchFactoryV2Mock());
        _execute(address(factory), abi.encodeCall(factory.upgradeToAndCall, (newImpl, "")));

        // The already-deployed curve's runtime bytecode is completely untouched by the factory upgrade.
        assertEq(address(curve1).codehash, codehashBefore, "pre-upgrade curve bytecode changed");
        // It still trades...
        vm.prank(alice);
        curve1.buy{value: 10e18}(0, address(0), type(uint256).max);
        // ...and still graduates, through the (unchanged) GraduationManager.
        _graduate(curve1);

        // A launch created AFTER the upgrade gets the new curve.
        (LaunchToken token2, BondingCurve curve2) = _create(bytes32(uint256(2)));
        assertEq(BondingCurveV2Mock(address(curve2)).version(), 2, "new launch did not get the V2 curve");

        // Factory state survived the upgrade.
        assertEq(factory.configHash(), keccak256(abi.encode(cfg)), "config did not survive");
        assertEq(factory.treasury(), treasuryAddr, "treasury did not survive");
        assertEq(factory.guardian(), guardian, "guardian did not survive");
        assertEq(factory.owner(), address(timelock), "owner did not survive");
        assertEq(factory.curveOf(address(token1)), address(curve1), "old curveOf entry lost");
        assertEq(factory.curveOf(address(token2)), address(curve2), "new curveOf entry missing");
    }

    // ================================================================== fee manager

    function test_feeManagerUpgradePreservesLedgerAndAppendedFieldIsZero() public {
        (LaunchToken token,) = _create(bytes32(uint256(1)));
        BondingCurve curve = BondingCurve(factory.curveOf(address(token)));

        vm.prank(alice);
        curve.buy{value: 100e18}(0, referrer, type(uint256).max); // binds `referrer` to alice
        vm.prank(bob);
        curve.buy{value: 50e18}(0, address(0), type(uint256).max); // unreferred

        uint256 creatorBalBefore = feeManager.balances(creator);
        uint256 referrerBalBefore = feeManager.balances(referrer);
        uint256 platformBefore = feeManager.platformBalance();
        uint256 totalOwedBefore = feeManager.totalOwed();
        address referrerOfAliceBefore = feeManager.referrerOf(alice);
        bool hasTradedAliceBefore = feeManager.hasTraded(alice);
        bool hasTradedBobBefore = feeManager.hasTraded(bob);
        IFeeManager.TokenInfo memory infoBefore = feeManager.tokenInfo(address(token));

        address newImpl = address(new FeeManagerV2Mock());
        _execute(address(feeManager), abi.encodeCall(feeManager.upgradeToAndCall, (newImpl, "")));

        assertEq(feeManager.balances(creator), creatorBalBefore, "creator balance lost");
        assertEq(feeManager.balances(referrer), referrerBalBefore, "referrer balance lost");
        assertEq(feeManager.platformBalance(), platformBefore, "platform balance lost");
        assertEq(feeManager.totalOwed(), totalOwedBefore, "totalOwed lost");
        assertEq(feeManager.referrerOf(alice), referrerOfAliceBefore, "referral binding lost");
        assertEq(feeManager.hasTraded(alice), hasTradedAliceBefore, "hasTraded(alice) lost");
        assertEq(feeManager.hasTraded(bob), hasTradedBobBefore, "hasTraded(bob) lost");
        IFeeManager.TokenInfo memory infoAfter = feeManager.tokenInfo(address(token));
        assertEq(infoAfter.curve, infoBefore.curve, "tokenInfo.curve lost");
        assertEq(infoAfter.creator, infoBefore.creator, "tokenInfo.creator lost");
        assertEq(infoAfter.tradeFeeBps, infoBefore.tradeFeeBps, "tokenInfo.tradeFeeBps lost");
        assertEq(infoAfter.creatorShareBps, infoBefore.creatorShareBps, "tokenInfo.creatorShareBps lost");
        assertEq(infoAfter.referrerShareBps, infoBefore.referrerShareBps, "tokenInfo.referrerShareBps lost");

        assertEq(FeeManagerV2Mock(address(feeManager)).extraField(), 0, "appended field is not zero");

        // Claims still pay exactly what was owed.
        uint256 owed = feeManager.balances(creator);
        assertGt(owed, 0);
        vm.prank(creator);
        uint256 paid = feeManager.claim(creator);
        assertEq(paid, owed, "claim did not pay exactly what was owed");
        assertEq(feeManager.balances(creator), 0, "balance not cleared after claim");
    }

    // ================================================================== graduation manager

    function test_graduationManagerUpgradeMidLifeGraduatesThroughV2Logic() public {
        (LaunchToken token, BondingCurve curve) = _create(bytes32(uint256(1)));
        assertEq(uint256(curve.phase()), uint256(BondingCurve.Phase.Trading), "curve should still be live");

        address newImpl = address(new GraduationManagerV2Mock());
        _execute(address(gm), abi.encodeCall(gm.upgradeToAndCall, (newImpl, "")));

        vm.recordLogs();
        vm.prank(bob);
        curve.buy{value: 30_000e18}(0, address(0), type(uint256).max);
        assertEq(uint256(curve.phase()), uint256(BondingCurve.Phase.Graduated), "did not graduate through V2");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 v2Topic = GraduationManagerV2Mock.GraduatedV2.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(gm) && logs[i].topics.length > 1 && logs[i].topics[0] == v2Topic) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
                found = true;
            }
        }
        assertTrue(found, "GraduatedV2 was not emitted by the upgraded GraduationManager");
    }

    // ================================================================== governance / timelock plumbing

    function test_directCallToUpgradeRevertsForNonOwners() public {
        address newImpl = address(new LaunchFactoryV2Mock());

        // The timelock's own admin is not the owner...
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        factory.upgradeToAndCall(newImpl, "");

        // ...and neither is anybody else.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.upgradeToAndCall(newImpl, "");
    }

    function test_executeBeforeMinDelayReverts() public {
        address newImpl = address(new LaunchFactoryV2Mock());
        bytes memory data = abi.encodeCall(factory.upgradeToAndCall, (newImpl, ""));
        bytes32 id = _schedule(address(factory), data);
        assertEq(uint256(timelock.getOperationState(id)), uint256(TimelockController.OperationState.Waiting));

        vm.prank(admin);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(factory), 0, data, bytes32(0), bytes32(0));
    }

    function test_cancelWorks() public {
        address newImpl = address(new LaunchFactoryV2Mock());
        bytes memory data = abi.encodeCall(factory.upgradeToAndCall, (newImpl, ""));
        bytes32 id = _schedule(address(factory), data);

        vm.prank(admin);
        timelock.cancel(id);
        assertEq(uint256(timelock.getOperationState(id)), uint256(TimelockController.OperationState.Unset));

        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(factory), 0, data, bytes32(0), bytes32(0));
    }

    function test_timelockSelfDelayChangeRequiresTheDelay() public {
        uint256 newDelay = minDelay * 2;
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        _schedule(address(timelock), data);

        vm.prank(admin);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));
        assertEq(timelock.getMinDelay(), newDelay, "delay did not change");
    }

    // ================================================================== initializers

    function test_initializeCannotBeCalledTwiceOnProxiesOrOnAnyImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(admin, admin, treasuryAddr, address(feeManager), address(gm), cfg);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        feeManager.initialize(address(factory), address(hook), address(gm), admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gm.initialize(
            address(factory), address(poolManager), address(posm), address(permit2), address(hook), address(locker),
            address(feeManager), USDC, admin
        );

        LaunchFactoryV2Mock lfImpl = new LaunchFactoryV2Mock();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        lfImpl.initialize(admin, admin, treasuryAddr, address(feeManager), address(gm), cfg);

        FeeManagerV2Mock fmV2Impl = new FeeManagerV2Mock();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fmV2Impl.initialize(address(factory), address(hook), address(gm), admin);

        GraduationManagerV2Mock gmV2Impl = new GraduationManagerV2Mock();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gmV2Impl.initialize(
            address(factory), address(poolManager), address(posm), address(permit2), address(hook), address(locker),
            address(feeManager), USDC, admin
        );
    }

    // ================================================================== guardian

    function test_guardianCanPauseAndUnpauseButCannotAdminister() public {
        vm.prank(guardian);
        factory.pause();
        assertTrue(factory.paused());
        vm.prank(guardian);
        factory.unpause();
        assertFalse(factory.paused());

        address newImpl = address(new LaunchFactoryV2Mock());
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.upgradeToAndCall(newImpl, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.setConfig(cfg);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.setTreasury(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.setGuardian(guardian);
        vm.stopPrank();
    }

    function test_ownerCanChangeGuardianThroughTimelock() public {
        address newGuardian = makeAddr("newGuardian");
        _execute(address(factory), abi.encodeCall(factory.setGuardian, (newGuardian)));
        assertEq(factory.guardian(), newGuardian);
    }

    function test_pauseDoesNotStopExistingLaunchActivity() public {
        (LaunchToken token, BondingCurve curve) = _create(bytes32(uint256(1)));
        vm.prank(alice);
        curve.buy{value: 50e18}(0, referrer, type(uint256).max);

        vm.prank(guardian);
        factory.pause();

        // New creation IS blocked...
        bytes32 pinned = factory.configHash();
        vm.prank(alice);
        vm.expectRevert();
        factory.createToken{value: cfg.launchFee}(_params(bytes32(uint256(2))), pinned, 0);

        // ...but the existing launch keeps trading, selling, graduating and paying claims.
        vm.prank(alice);
        token.approve(address(curve), 1e18);
        vm.prank(alice);
        curve.sell(1e18, 0, address(0), type(uint256).max);

        _graduate(curve);

        uint256 owed = feeManager.balances(creator);
        assertGt(owed, 0);
        vm.prank(creator);
        feeManager.claim(creator);
    }

    // ================================================================== two-step, timelocked ownership

    function _assertTwoStepTimelockedOwnership(address proxy) internal {
        IOwnable2StepMinimal c = IOwnable2StepMinimal(proxy);
        address newOwner = makeAddr(string.concat("newOwnerFor", vm.toString(proxy)));
        address prevOwner = c.owner();
        assertEq(prevOwner, address(timelock));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        c.transferOwnership(newOwner);

        _execute(proxy, abi.encodeCall(c.transferOwnership, (newOwner)));
        assertEq(c.owner(), prevOwner, "ownership moved before acceptOwnership");
        assertEq(c.pendingOwner(), newOwner);

        vm.prank(newOwner);
        c.acceptOwnership();
        assertEq(c.owner(), newOwner);
    }

    function test_factoryOwnershipTransferIsTwoStepAndTimelocked() public {
        _assertTwoStepTimelockedOwnership(address(factory));
    }

    function test_feeManagerOwnershipTransferIsTwoStepAndTimelocked() public {
        _assertTwoStepTimelockedOwnership(address(feeManager));
    }

    function test_graduationManagerOwnershipTransferIsTwoStepAndTimelocked() public {
        _assertTwoStepTimelockedOwnership(address(gm));
    }

    // ================================================================== pinned UUPS edge cases

    function test_upgradeToNonUUPSContractReverts() public {
        bytes memory data = abi.encodeCall(factory.upgradeToAndCall, (address(locker), ""));
        _schedule(address(factory), data);
        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(locker)));
        timelock.execute(address(factory), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev A target with code that simply lacks `proxiableUUID` (see `test_upgradeToNonUUPSContractReverts`)
    ///      fails the call cleanly, which the UUPS try/catch turns into `ERC1967InvalidImplementation`. An EOA
    ///      has no code at all, so Solidity's own no-code guard around the high-level `IERC1822Proxiable(...)`
    ///      call fails with EMPTY return data; that empty-data failure is what `Address.verifyCallResult`
    ///      (used by both `ERC1967Utils.upgradeToAndCall`'s internal machinery and, here, the timelock's
    ///      `execute`) turns into the generic `Errors.FailedCall()` instead. Either way, the upgrade reverts.
    function test_upgradeToEOAReverts() public {
        address eoa = makeAddr("eoaTarget");
        bytes memory data = abi.encodeCall(factory.upgradeToAndCall, (eoa, ""));
        _schedule(address(factory), data);
        vm.warp(block.timestamp + minDelay);
        vm.prank(admin);
        vm.expectPartialRevert(Errors.FailedCall.selector);
        timelock.execute(address(factory), 0, data, bytes32(0), bytes32(0));
    }

    function test_proxiableUUIDThroughTheProxyReverts() public {
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        factory.proxiableUUID();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        feeManager.proxiableUUID();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        gm.proxiableUUID();
    }

    function test_upgradeToAndCallOnImplementationDirectlyReverts() public {
        LaunchFactory freshFactoryImpl = new LaunchFactory();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        freshFactoryImpl.upgradeToAndCall(address(0), "");

        FeeManager freshFeeManagerImpl = new FeeManager();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        freshFeeManagerImpl.upgradeToAndCall(address(0), "");

        GraduationManager freshGmImpl = new GraduationManager();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        freshGmImpl.upgradeToAndCall(address(0), "");
    }
}
