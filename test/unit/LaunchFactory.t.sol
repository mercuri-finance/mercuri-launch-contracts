// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {LaunchConfig, CreateParams} from "../../src/libraries/LaunchTypes.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {DefaultConfig} from "../../script/DefaultConfig.sol";
import {MockGraduationManager} from "../utils/MockGraduationManager.sol";
import {Proxies} from "../utils/Proxies.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LaunchFactoryTest is Test {
    LaunchFactory factory;
    FeeManager fm;
    MockGraduationManager gm;
    LaunchConfig cfg;
    /// @dev M4: `expectedConfigHash` is mandatory, so every `createToken` here has to pin a hash. Cached in
    ///      setUp because reading `factory.configHash()` inside the argument list of a call guarded by
    ///      `vm.expectRevert` would consume the expectation on that inner staticcall instead.
    bytes32 pinnedHash;

    /// @dev The test contract stands in for the timelock that owns the factory proxy.
    address owner = address(this);
    address guardian = makeAddr("guardian");
    address treasuryAddr = makeAddr("treasury");
    address alice = makeAddr("alice");
    address creator = makeAddr("creator");
    address referrer = makeAddr("referrer");

    function setUp() public {
        cfg = DefaultConfig.get();
        gm = new MockGraduationManager();
        // FeeManager and factory reference each other: predict the factory PROXY's address. Each Proxies helper
        // deploys implementation then proxy, so after the FeeManager pair the factory proxy is the 4th CREATE.
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        fm = Proxies.feeManager(predictedFactory, makeAddr("hook"), address(gm), address(this));
        factory = Proxies.launchFactory(owner, guardian, treasuryAddr, address(fm), address(gm), cfg);
        assertEq(address(factory), predictedFactory);
        pinnedHash = factory.configHash();
        vm.deal(alice, 100_000e18);
    }

    function _params(bytes32 salt) internal view returns (CreateParams memory) {
        return CreateParams("Example", "EX", "https://example.invalid/m.json", creator, referrer, salt);
    }

    function test_createWithoutInitialBuy() public {
        (address predictedToken, address predictedCurve) = factory.computeAddresses(alice, _params("a"));
        vm.prank(alice);
        (address token, address curve) = factory.createToken{value: 1e18}(_params("a"), pinnedHash, 0);

        assertEq(token, predictedToken);
        assertEq(curve, predictedCurve);
        assertEq(factory.curveOf(token), curve);
        assertEq(LaunchToken(token).balanceOf(curve), 1_000_000_000e18);
        assertEq(BondingCurve(curve).factory(), address(factory));
        assertEq(fm.platformBalance(), 1e18); // launch fee
        assertEq(fm.tokenInfo(token).creator, creator);
        assertEq(fm.tokenInfo(token).curve, curve);
    }

    function test_initialBuyIsTaxFreeAndGoesToDeployer() public {
        vm.prank(alice);
        (address token, address curve) = factory.createToken{value: 101e18}(_params("a"), pinnedHash, 0);
        uint256 expected = CurveMath.tokensForUsdc(cfg.virtualUsdc, cfg.virtualTokens, 99e18);
        assertEq(LaunchToken(token).balanceOf(alice), expected);
        assertEq(BondingCurve(curve).realUsdc(), 99e18);
        assertEq(fm.referrerOf(alice), referrer);
        assertEq(fm.balances(referrer), 0.2e18);
    }

    function test_initialBuyRespectsMinTokensOutAndCap() public {
        vm.startPrank(alice);
        vm.expectRevert(BondingCurve.Slippage.selector);
        factory.createToken{value: 101e18}(_params("a"), pinnedHash, type(uint256).max);
        vm.expectRevert(BondingCurve.InitialBuyTooLarge.selector);
        factory.createToken{value: 1_001e18}(_params("b"), pinnedHash, 0);
        vm.stopPrank();
    }

    function test_launchFeeRequired() public {
        vm.prank(alice);
        vm.expectRevert(LaunchFactory.InsufficientLaunchFee.selector);
        factory.createToken{value: 0.5e18}(_params("a"), pinnedHash, 0);
    }

    function test_sameSaltSameDeployerReverts() public {
        vm.startPrank(alice);
        factory.createToken{value: 1e18}(_params("a"), pinnedHash, 0);
        vm.expectRevert();
        factory.createToken{value: 1e18}(_params("a"), pinnedHash, 0);
        vm.stopPrank();
    }

    function test_configPinning() public {
        bytes32 pinned = factory.configHash();
        LaunchConfig memory next = cfg;
        next.tradeFeeBps = 200;
        vm.prank(owner);
        factory.setConfig(next);
        bytes32 updated = factory.configHash();

        vm.startPrank(alice);
        vm.expectRevert(LaunchFactory.ConfigChanged.selector);
        factory.createToken{value: 1e18}(_params("a"), pinned, 0);
        factory.createToken{value: 1e18}(_params("a"), updated, 0); // pinned to the new terms
        vm.stopPrank();
    }

    /// @dev M4: the zero hash used to be a wildcard that skipped the pinning check entirely, so an integrator
    ///      who simply left the field empty silently accepted whatever terms the owner had set a block earlier.
    ///      It is now just another wrong hash.
    function test_zeroConfigHashIsNotAWildcard() public {
        vm.prank(alice);
        vm.expectRevert(LaunchFactory.ConfigChanged.selector);
        factory.createToken{value: 1e18}(_params("a"), bytes32(0), 0);

        // And the correct hash still works, so this is a pinning rule, not a blanket refusal.
        vm.prank(alice);
        (address token,) = factory.createToken{value: 1e18}(_params("a"), pinnedHash, 0);
        assertEq(factory.curveOf(token) != address(0), true);
    }

    /// @dev Reviewer coverage (e): ownership moves only through the two-step handshake.
    function test_ownershipTransferIsTwoStep() public {
        vm.prank(owner);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), owner, "owner must not change until the transfer is accepted");
        assertEq(factory.pendingOwner(), alice);

        vm.prank(creator); // not the pending owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factory.acceptOwnership();

        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
        assertEq(factory.pendingOwner(), address(0));

        // The old owner is now an ordinary account. `pause` is owner-or-guardian since the upgradeability
        // work, so it reverts with that error; the owner-only admin functions still revert the Ownable way.
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
        factory.pause();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        factory.setTreasury(owner);
    }

    /// @dev Reviewer coverage (e): the factory owner is the system's only admin, and even so has no reach into
    ///      a curve that already exists — neither its funds nor its terms.
    function test_ownerCannotMoveCurveFundsOrChangeExistingCurveTerms() public {
        vm.prank(alice);
        (address token, address curveAddr) = factory.createToken{value: 1e18}(_params("a"), pinnedHash, 0);
        BondingCurve curve = BondingCurve(curveAddr);
        vm.roll(block.number + cfg.snipeBlocks);
        vm.prank(alice);
        curve.buy{value: 1_000e18}(0, address(0), type(uint256).max);

        uint256 reserve = address(curve).balance;
        uint256 ownerBalanceBefore = owner.balance;
        assertGt(reserve, 0);

        vm.startPrank(owner);
        // No owner-only entry point exists on the curve; the two that gate on an address both refuse.
        vm.expectRevert(BondingCurve.Unauthorized.selector);
        curve.executeGraduation();
        vm.expectRevert(BondingCurve.Unauthorized.selector);
        curve.initialBuy(owner, address(0), 0);

        // The only lever the owner does have — the config — is not retroactive, and re-pointing the treasury
        // cannot reach a curve's reserve either (curves never pay the treasury; they pay the FeeManager).
        LaunchConfig memory harsher = cfg;
        harsher.tradeFeeBps = 500;
        harsher.launchFee = 100e18;
        harsher.snipeStartBps = 9_900;
        factory.setConfig(harsher);
        factory.setTreasury(owner);
        vm.stopPrank();

        assertEq(address(curve).balance, reserve, "curve reserve untouched");
        assertEq(owner.balance, ownerBalanceBefore, "owner gained nothing");
        assertEq(curve.tradeFeeBps(), cfg.tradeFeeBps, "existing curve keeps its fee");
        assertEq(curve.snipeStartBps(), cfg.snipeStartBps);
        assertEq(curve.curveSupply(), cfg.curveSupply);
        assertEq(curve.virtualUsdc(), cfg.virtualUsdc);
        assertEq(fm.tradeFeeBps(token), cfg.tradeFeeBps, "and so does its FeeManager record");
    }

    function test_configChangeIsNeverRetroactive() public {
        vm.prank(alice);
        (address token, address curve) = factory.createToken{value: 1e18}(_params("a"), pinnedHash, 0);
        LaunchConfig memory next = cfg;
        next.tradeFeeBps = 200;
        next.snipeBlocks = cfg.snipeBlocks + 100;
        vm.prank(owner);
        factory.setConfig(next);
        assertEq(BondingCurve(curve).tradeFeeBps(), 100);
        assertEq(BondingCurve(curve).snipeBlocks(), cfg.snipeBlocks);
        assertEq(fm.tradeFeeBps(token), 100);
    }

    function test_setConfigBounds() public {
        vm.startPrank(owner);
        LaunchConfig memory c = cfg;
        c.tradeFeeBps = 501;
        vm.expectRevert(LaunchFactory.InvalidConfig.selector);
        factory.setConfig(c);

        c = cfg;
        c.poolSupply = 100_000_000e18; // supply no longer sums to 1B
        vm.expectRevert(LaunchFactory.InvalidConfig.selector);
        factory.setConfig(c);

        c = cfg;
        c.creatorShareBps = 9_000; // 9000 + 2000 > 10000
        vm.expectRevert(LaunchFactory.InvalidConfig.selector);
        factory.setConfig(c);

        c = cfg;
        c.snipeStartBps = 10_000;
        vm.expectRevert(LaunchFactory.InvalidConfig.selector);
        factory.setConfig(c);

        c = cfg;
        c.virtualTokens = 900_000_000e18; // pool would need more USDC than the curve collects
        vm.expectRevert(LaunchFactory.InvalidConfig.selector);
        factory.setConfig(c);
        vm.stopPrank();
    }

    function test_alternativeConsistentConfigsAccepted() public {
        vm.startPrank(owner);
        LaunchConfig memory c = cfg;
        c.virtualUsdc = 25_000e18 / uint256(3); // 25,000 USDC graduation
        factory.setConfig(c);
        c.virtualUsdc = 0.5e18; // tiny curve used by the testnet smoke run; needed = 1.5e18, still >= 1 USDC
        c.launchFee = 0.1e18;
        factory.setConfig(c);
        vm.stopPrank();
    }

    /// @dev Fix round 2: the live-testnet graduation-overflow incident traced back to a config whose pool
    ///      seeding amount was small enough that the 6-decimal USDC leg lost most of its price resolution.
    ///      Below 1 USDC (18-dec wei) of seeding, reject at config time rather than let it reach
    ///      `GraduationManager.graduate` (where it could even hit `NothingToSeed`).
    function test_setConfigRejectsPoolSeedingBelowOneUsdc() public {
        vm.startPrank(owner);
        LaunchConfig memory c = cfg;
        c.virtualUsdc = 0.3e18; // needed = 0.9e18 < 1e18
        vm.expectRevert(LaunchFactory.InvalidConfig.selector);
        factory.setConfig(c);
        vm.stopPrank();
    }

    function test_onlyOwnerAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setConfig(cfg);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setTreasury(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setGuardian(alice);
        // `pause` is owner-or-guardian (upgradeability design section 3), hence its own error.
        vm.expectRevert(LaunchFactory.NotOwnerOrGuardian.selector);
        factory.pause();
        vm.stopPrank();
    }

    function test_pauseBlocksCreationOnly() public {
        vm.prank(alice);
        (, address curve) = factory.createToken{value: 1e18}(_params("a"), pinnedHash, 0);
        vm.prank(owner);
        factory.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createToken{value: 1e18}(_params("b"), pinnedHash, 0);

        vm.roll(block.number + 10);
        vm.prank(alice);
        BondingCurve(curve).buy{value: 10e18}(0, address(0), type(uint256).max); // existing launches keep trading
    }

    function test_paramValidation() public {
        vm.startPrank(alice);
        CreateParams memory p = _params("a");
        p.creator = address(0);
        vm.expectRevert(LaunchFactory.InvalidParams.selector);
        factory.createToken{value: 1e18}(p, pinnedHash, 0);

        p = _params("a");
        p.name = "";
        vm.expectRevert(LaunchFactory.InvalidParams.selector);
        factory.createToken{value: 1e18}(p, pinnedHash, 0);

        p = _params("a");
        p.symbol = "WAYTOOLONGSYMBOL";
        vm.expectRevert(LaunchFactory.InvalidParams.selector);
        factory.createToken{value: 1e18}(p, pinnedHash, 0);
        vm.stopPrank();
    }

    function test_setTreasury() public {
        vm.prank(owner);
        factory.setTreasury(alice);
        assertEq(factory.treasury(), alice);
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.InvalidParams.selector);
        factory.setTreasury(address(0));
    }
}
