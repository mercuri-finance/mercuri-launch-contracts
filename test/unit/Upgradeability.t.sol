// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";
import {DefaultConfig} from "../../script/DefaultConfig.sol";

/// @dev Proxy wiring of the three upgradeable singletons: implementations are locked, proxies point at them,
///      and each contract's state lives at its ERC-7201 namespaced slot. The test contract plays the timelock.
contract UpgradeabilityTest is Test {
    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal factoryAddr = makeAddr("factory");
    address internal hookAddr = makeAddr("hook");
    address internal gmAddr = makeAddr("gm");
    address internal fmAddr = makeAddr("fm");
    address internal poolManagerAddr = makeAddr("poolManager");
    address internal posmAddr = makeAddr("posm");
    address internal permit2Addr = makeAddr("permit2");
    address internal lockerAddr = makeAddr("locker");
    address internal usdcAddr = makeAddr("usdc");
    address internal treasuryAddr = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    FeeManager internal fmImpl;
    GraduationManager internal gmImpl;
    LaunchFactory internal factoryImpl;
    FeeManager internal fm;
    GraduationManager internal gm;
    LaunchFactory internal factory;
    LaunchConfig internal cfg;

    event GuardianUpdated(address guardian);

    function setUp() public {
        cfg = DefaultConfig.get();

        fmImpl = new FeeManager();
        fm = FeeManager(
            address(
                new ERC1967Proxy(
                    address(fmImpl), abi.encodeCall(FeeManager.initialize, (factoryAddr, hookAddr, gmAddr, address(this)))
                )
            )
        );

        gmImpl = new GraduationManager();
        gm = GraduationManager(
            address(
                new ERC1967Proxy(
                    address(gmImpl),
                    abi.encodeCall(
                        GraduationManager.initialize,
                        (
                            factoryAddr,
                            poolManagerAddr,
                            posmAddr,
                            permit2Addr,
                            hookAddr,
                            lockerAddr,
                            fmAddr,
                            usdcAddr,
                            address(this)
                        )
                    )
                )
            )
        );

        factoryImpl = new LaunchFactory();
        factory = LaunchFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeCall(
                        LaunchFactory.initialize, (address(this), guardian, treasuryAddr, fmAddr, gmAddr, cfg)
                    )
                )
            )
        );
    }

    function _namespace(string memory ns) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1)) & ~bytes32(uint256(0xff));
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    // ------------------------------------------------------------ implementation slot

    function test_proxiesPointAtTheirImplementations() public view {
        assertEq(_implementationOf(address(fm)), address(fmImpl), "FeeManager implementation slot");
        assertEq(_implementationOf(address(gm)), address(gmImpl), "GraduationManager implementation slot");
        assertEq(_implementationOf(address(factory)), address(factoryImpl), "LaunchFactory implementation slot");
    }

    // ------------------------------------------------------------ initializers

    function test_implementationsRejectInitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fmImpl.initialize(factoryAddr, hookAddr, gmAddr, stranger);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gmImpl.initialize(
            factoryAddr, poolManagerAddr, posmAddr, permit2Addr, hookAddr, lockerAddr, fmAddr, usdcAddr, stranger
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factoryImpl.initialize(stranger, stranger, treasuryAddr, fmAddr, gmAddr, cfg);
    }

    function test_proxiesRejectSecondInitialize() public {
        vm.startPrank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fm.initialize(factoryAddr, hookAddr, gmAddr, stranger);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gm.initialize(
            factoryAddr, poolManagerAddr, posmAddr, permit2Addr, hookAddr, lockerAddr, fmAddr, usdcAddr, stranger
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(stranger, stranger, treasuryAddr, fmAddr, gmAddr, cfg);
        vm.stopPrank();
    }

    function test_initializeWiresOwnerAndPeers() public view {
        assertEq(fm.owner(), address(this));
        assertEq(address(fm.factory()), factoryAddr);
        assertEq(fm.hook(), hookAddr);
        assertEq(fm.graduationManager(), gmAddr);

        assertEq(gm.owner(), address(this));
        assertEq(address(gm.factory()), factoryAddr);
        assertEq(address(gm.poolManager()), poolManagerAddr);
        assertEq(address(gm.positionManager()), posmAddr);
        assertEq(address(gm.permit2()), permit2Addr);
        assertEq(gm.hook(), hookAddr);
        assertEq(address(gm.locker()), lockerAddr);
        assertEq(address(gm.feeManager()), fmAddr);
        assertEq(gm.usdc(), usdcAddr);

        assertEq(factory.owner(), address(this));
        assertEq(factory.guardian(), guardian);
        assertEq(factory.treasury(), treasuryAddr);
        assertEq(address(factory.feeManager()), fmAddr);
        assertEq(factory.graduationManager(), gmAddr);
        assertEq(factory.configHash(), keccak256(abi.encode(cfg)));
    }

    // ------------------------------------------------------------ ERC-7201 namespaces

    /// @dev The first field of each namespaced struct is read straight from the slot the ERC-7201 formula gives
    ///      for its namespace, which pins the contract's `*_STORAGE_LOCATION` constant to that formula.
    function test_storageLivesAtErc7201Namespaces() public view {
        bytes32 fmSlot = _namespace("launchpad.storage.FeeManager");
        bytes32 gmSlot = _namespace("launchpad.storage.GraduationManager");
        bytes32 factorySlot = _namespace("launchpad.storage.LaunchFactory");

        assertEq(vm.load(address(fm), fmSlot), bytes32(uint256(uint160(factoryAddr))), "FeeManager namespace");
        assertEq(vm.load(address(gm), gmSlot), bytes32(uint256(uint160(factoryAddr))), "GraduationManager namespace");
        assertEq(vm.load(address(factory), factorySlot), bytes32(uint256(uint160(fmAddr))), "LaunchFactory namespace");

        // The implementations themselves hold none of it.
        assertEq(vm.load(address(fmImpl), fmSlot), bytes32(0));
        assertEq(vm.load(address(gmImpl), gmSlot), bytes32(0));
        assertEq(vm.load(address(factoryImpl), factorySlot), bytes32(0));
    }

    // ------------------------------------------------------------ upgrades are owner-only

    function test_onlyOwnerCanUpgrade() public {
        address newFm = address(new FeeManager());
        address newGm = address(new GraduationManager());
        address newFactory = address(new LaunchFactory());

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fm.upgradeToAndCall(newFm, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        gm.upgradeToAndCall(newGm, "");
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.upgradeToAndCall(newFactory, "");

        fm.upgradeToAndCall(newFm, "");
        gm.upgradeToAndCall(newGm, "");
        factory.upgradeToAndCall(newFactory, "");
        assertEq(_implementationOf(address(fm)), newFm);
        assertEq(_implementationOf(address(gm)), newGm);
        assertEq(_implementationOf(address(factory)), newFactory);
        assertEq(factory.configHash(), keccak256(abi.encode(cfg)), "state survives the upgrade");
    }

    // ------------------------------------------------------------ renounceOwnership is disabled

    function test_ownerCannotRenounceFeeManager() public {
        vm.expectRevert(FeeManager.RenounceDisabled.selector);
        fm.renounceOwnership();
        assertEq(fm.owner(), address(this));
    }

    function test_ownerCannotRenounceGraduationManager() public {
        vm.expectRevert(GraduationManager.RenounceDisabled.selector);
        gm.renounceOwnership();
        assertEq(gm.owner(), address(this));
    }

    function test_ownerCannotRenounceLaunchFactory() public {
        vm.expectRevert(LaunchFactory.RenounceDisabled.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), address(this));
    }

    // ------------------------------------------------------------ factory guardian

    /// @dev `address(0)` means "no guardian": only the owner can pause / unpause, and the zero address gains
    ///      nothing from being the stored value.
    function test_zeroGuardianLeavesOnlyOwnerPausing() public {
        factory.setGuardian(address(0));
        assertEq(factory.guardian(), address(0));

        address[3] memory others = [guardian, stranger, address(0)];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
            factory.pause();
        }

        factory.pause();
        assertTrue(factory.paused());
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
            factory.unpause();
        }
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_initializeWithZeroGuardian() public {
        LaunchFactory f = LaunchFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeCall(
                        LaunchFactory.initialize, (address(this), address(0), treasuryAddr, fmAddr, gmAddr, cfg)
                    )
                )
            )
        );
        assertEq(f.guardian(), address(0));
        vm.prank(stranger);
        vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
        f.pause();
        f.pause();
        assertTrue(f.paused());
    }

    function test_guardianCanPauseAndUnpause() public {
        vm.prank(guardian);
        factory.pause();
        assertTrue(factory.paused());
        vm.prank(guardian);
        factory.unpause();
        assertFalse(factory.paused());

        // The owner can too.
        factory.pause();
        factory.unpause();
    }

    function test_strangerCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
        factory.pause();

        factory.pause();
        vm.prank(stranger);
        vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
        factory.unpause();
    }

    function test_guardianCannotAdminister() public {
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.setConfig(cfg);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.setTreasury(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.setGuardian(stranger);
        vm.stopPrank();
    }

    function test_setGuardianOnlyOwner() public {
        vm.expectEmit(address(factory));
        emit GuardianUpdated(stranger);
        factory.setGuardian(stranger);
        assertEq(factory.guardian(), stranger);

        // The previous guardian lost the power, the new one has it.
        vm.prank(guardian);
        vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
        factory.pause();
        vm.prank(stranger);
        factory.pause();
        assertTrue(factory.paused());
    }
}
