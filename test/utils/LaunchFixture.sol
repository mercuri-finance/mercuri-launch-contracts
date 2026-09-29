// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4Fixture} from "./V4Fixture.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";
import {DefaultConfig} from "../../script/DefaultConfig.sol";
import {LaunchConfig, CreateParams} from "../../src/libraries/LaunchTypes.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LiquidityLocker} from "../../src/LiquidityLocker.sol";
import {LaunchHook} from "../../src/LaunchHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev The whole system wired in the deployment order of the upgradeability design (spec section 5): the three
///      implementations, then the hook (CREATE2, salt mined over the predicted FeeManager / GraduationManager
///      PROXY addresses), the locker (pointing at the GraduationManager proxy), and finally the FeeManager,
///      GraduationManager and LaunchFactory proxies, each initialised in its constructor. The timelock comes in
///      a later task: here the test contract itself is the owner of all three proxies.
abstract contract LaunchFixture is V4Fixture {
    LaunchFactory internal factory;
    FeeManager internal feeManager;
    GraduationManager internal gm;
    LiquidityLocker internal locker;
    LaunchHook internal hook;
    LaunchConfig internal cfg;

    /// @dev Stands in for the timelock: owner of all three proxies.
    address internal owner = address(this);
    address internal guardian = makeAddr("guardian");
    address internal treasuryAddr = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal referrer = makeAddr("referrer");

    function _deploySystem() internal {
        _deployV4();
        cfg = DefaultConfig.get();

        address feeManagerImpl = address(new FeeManager());
        address gmImpl = address(new GraduationManager());
        address factoryImpl = address(new LaunchFactory());

        // CREATE2 still bumps this contract's nonce: hook at `nonce`, locker +1, then the three proxies.
        uint64 nonce = vm.getNonce(address(this));
        address lockerAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address feeManagerAddr = vm.computeCreateAddress(address(this), nonce + 2);
        address gmAddr = vm.computeCreateAddress(address(this), nonce + 3);
        address factoryAddr = vm.computeCreateAddress(address(this), nonce + 4);

        bytes memory hookArgs = abi.encode(address(poolManager), feeManagerAddr, gmAddr, USDC);
        // RULING: computed explicitly rather than via `LaunchHook(address(0)).FLAGS()`, which would perform an
        // external call on the zero address and revert at runtime.
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, abi.encodePacked(type(LaunchHook).creationCode, hookArgs));

        hook = new LaunchHook{salt: salt}(address(poolManager), feeManagerAddr, gmAddr, USDC);
        locker = new LiquidityLocker(address(posm), gmAddr);
        feeManager = FeeManager(
            address(
                new ERC1967Proxy(
                    feeManagerImpl, abi.encodeCall(FeeManager.initialize, (factoryAddr, hookAddr, gmAddr, owner))
                )
            )
        );
        gm = GraduationManager(
            address(
                new ERC1967Proxy(
                    gmImpl,
                    abi.encodeCall(
                        GraduationManager.initialize,
                        (
                            factoryAddr,
                            address(poolManager),
                            address(posm),
                            address(permit2),
                            hookAddr,
                            lockerAddr,
                            feeManagerAddr,
                            USDC,
                            owner
                        )
                    )
                )
            )
        );
        factory = LaunchFactory(
            address(
                new ERC1967Proxy(
                    factoryImpl,
                    abi.encodeCall(
                        LaunchFactory.initialize, (owner, guardian, treasuryAddr, feeManagerAddr, gmAddr, cfg)
                    )
                )
            )
        );

        require(address(hook) == hookAddr, "hook address");
        require(address(feeManager) == feeManagerAddr, "feeManager address");
        require(address(gm) == gmAddr, "gm address");
        require(address(locker) == lockerAddr, "locker address");
        require(address(factory) == factoryAddr, "factory address");

        vm.deal(alice, 1_000_000e18);
        vm.deal(bob, 1_000_000e18);
    }

    function _params(bytes32 salt) internal view returns (CreateParams memory) {
        return CreateParams("Example", "EX", "https://example.invalid/m.json", creator, address(0), salt);
    }

    function _create(bytes32 salt) internal returns (LaunchToken token, BondingCurve curve) {
        // M4: `expectedConfigHash` is mandatory now, so every creation pins the factory's current hash. Read
        // BEFORE `vm.prank`: an external call inside the argument list would consume the prank, and
        // `createToken` would then run as this contract rather than as `alice` — changing the curve's CREATE2
        // salt and silently breaking `_createOrdered`'s address prediction.
        bytes32 pinned = factory.configHash();
        vm.prank(alice);
        (address t, address c) = factory.createToken{value: cfg.launchFee}(_params(salt), pinned, 0);
        (token, curve) = (LaunchToken(t), BondingCurve(c));
        // TOOLCHAIN QUIRK: under via-IR + optimizer, solc caches `block.number` within a function, so a second
        // read after `vm.roll` is stale. Use `vm.getBlockNumber()` instead of `block.number` here.
        vm.roll(vm.getBlockNumber() + cfg.snipeBlocks);
    }

    /// @dev Creates a launch whose token address sorts below (or above) USDC, to cover both pool orderings.
    function _createOrdered(bool tokenBelowUsdc) internal returns (LaunchToken token, BondingCurve curve) {
        for (uint256 i; i < 256; ++i) {
            bytes32 salt = bytes32(i + 1_000);
            (address predicted,) = factory.computeAddresses(alice, _params(salt));
            if ((predicted < USDC) == tokenBelowUsdc) return _create(salt);
        }
        revert("no salt for requested ordering");
    }

    function _graduate(BondingCurve curve) internal {
        vm.prank(bob);
        curve.buy{value: 30_000e18}(0, address(0), type(uint256).max);
        require(curve.phase() == BondingCurve.Phase.Graduated, "not graduated");
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return gm.poolKey(token);
    }
}
