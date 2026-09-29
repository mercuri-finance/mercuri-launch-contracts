// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {IFeeManager} from "../../src/interfaces/IFeeManager.sol";
import {Proxies} from "../utils/Proxies.sol";

contract FeeManagerTest is Test {
    FeeManager fm;
    address hook = makeAddr("hook");
    address gm = makeAddr("gm");
    address treasuryAddr = makeAddr("treasury");
    address token = makeAddr("token");
    address curve = makeAddr("curve");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");
    address referrer = makeAddr("referrer");

    // The test contract plays the factory.
    function treasury() external view returns (address) { return treasuryAddr; }

    function setUp() public {
        fm = Proxies.feeManager(address(this), hook, gm, address(this));
        fm.registerToken(token, curve, creator, 100, 5_000, 2_000);
        vm.deal(curve, 1_000e18);
    }

    /// @dev Low: `registerToken` re-validates the share split instead of trusting the factory. Shares summing
    ///      above 100% would make `_split`'s `amount - creatorAmount - referrerAmount` underflow, i.e. brick
    ///      every trade on that token.
    function test_registerTokenRejectsSharesAboveOneHundredPercent() public {
        vm.expectRevert(IFeeManager.InvalidShares.selector);
        fm.registerToken(makeAddr("t2"), makeAddr("c2"), creator, 100, 9_000, 2_000);

        // Exactly 100% is still fine (the platform simply gets nothing).
        fm.registerToken(makeAddr("t3"), makeAddr("c3"), creator, 100, 8_000, 2_000);
        assertEq(fm.tokenInfo(makeAddr("t3")).creatorShareBps, 8_000);
    }

    function test_registerOnlyFactoryAndOnlyOnce() public {
        vm.prank(trader);
        vm.expectRevert(IFeeManager.Unauthorized.selector);
        fm.registerToken(makeAddr("t2"), curve, creator, 100, 5_000, 2_000);

        vm.expectRevert(IFeeManager.AlreadyRegistered.selector);
        fm.registerToken(token, curve, creator, 100, 5_000, 2_000);
    }

    /// @dev Simulates a future factory violating the immutable hook's denominator precondition.
    function testFuzz_registerRejectsInvalidTradeFee(uint16 bps) public {
        bps = uint16(bound(bps, 10_000, type(uint16).max));
        address newToken = makeAddr("invalid-fee-token");
        vm.expectRevert(IFeeManager.InvalidTradeFee.selector);
        fm.registerToken(newToken, curve, creator, bps, 5_000, 2_000);
        assertEq(fm.tokenInfo(newToken).curve, address(0));
    }

    function test_registerTradeFeeDomainBoundaries() public {
        address zeroFeeToken = makeAddr("zero-fee-token");
        address maxFeeToken = makeAddr("max-fee-token");
        fm.registerToken(zeroFeeToken, curve, creator, 0, 5_000, 2_000);
        fm.registerToken(maxFeeToken, curve, creator, 9_999, 5_000, 2_000);
        assertEq(fm.tradeFeeBps(zeroFeeToken), 0);
        assertEq(fm.tradeFeeBps(maxFeeToken), 9_999);
    }

    function test_splitWithReferrer() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, referrer);
        assertEq(fm.balances(creator), 5e18);
        assertEq(fm.balances(referrer), 2e18);
        assertEq(fm.platformBalance(), 3e18);
        assertEq(fm.totalOwed(), 10e18);
        assertEq(fm.referrerOf(trader), referrer);
    }

    function test_splitWithoutReferrer() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, address(0));
        assertEq(fm.balances(creator), 5e18);
        assertEq(fm.platformBalance(), 5e18);
    }

    function test_referrerFixedAtFirstTrade() public {
        vm.startPrank(curve);
        fm.accrueTradeFee{value: 1e18}(token, trader, address(0)); // first trade, no referrer
        fm.accrueTradeFee{value: 1e18}(token, trader, referrer); // too late
        vm.stopPrank();
        assertEq(fm.referrerOf(trader), address(0));
        assertTrue(fm.hasTraded(trader));
        assertEq(fm.balances(referrer), 0);
    }

    function test_referrerCannotBeReplaced() public {
        address other = makeAddr("other");
        vm.startPrank(curve);
        fm.accrueTradeFee{value: 1e18}(token, trader, referrer);
        fm.accrueTradeFee{value: 1e18}(token, trader, other);
        vm.stopPrank();
        assertEq(fm.referrerOf(trader), referrer);
        assertEq(fm.balances(other), 0);
    }

    function test_selfReferralIgnored() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, trader);
        assertEq(fm.referrerOf(trader), address(0));
        assertEq(fm.platformBalance(), 5e18);
    }

    function test_onlyRegisteredCurveMayAccrueTradeFees() public {
        vm.deal(trader, 1e18);
        vm.prank(trader);
        vm.expectRevert(IFeeManager.Unauthorized.selector);
        fm.accrueTradeFee{value: 1e18}(token, trader, referrer);
    }

    function test_bindReferrerSelfService() public {
        vm.prank(trader);
        fm.bindReferrer(referrer);
        assertEq(fm.referrerOf(trader), referrer);

        vm.prank(trader);
        vm.expectRevert(IFeeManager.ReferrerLocked.selector);
        fm.bindReferrer(makeAddr("other"));
    }

    function test_bindReferrerRejectedAfterTrading() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 1e18}(token, trader, address(0));
        vm.prank(trader);
        vm.expectRevert(IFeeManager.ReferrerLocked.selector);
        fm.bindReferrer(referrer);
    }

    function test_bindReferrerRejectsSelfAndZero() public {
        vm.startPrank(trader);
        vm.expectRevert(IFeeManager.InvalidReferrer.selector);
        fm.bindReferrer(trader);
        vm.expectRevert(IFeeManager.InvalidReferrer.selector);
        fm.bindReferrer(address(0));
        vm.stopPrank();
    }

    function test_claimPaysAndZeroes() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, referrer);
        address payout = makeAddr("payout");
        vm.prank(creator);
        uint256 amount = fm.claim(payout);
        assertEq(amount, 5e18);
        assertEq(payout.balance, 5e18);
        assertEq(fm.balances(creator), 0);
        assertEq(fm.totalOwed(), 5e18);

        vm.prank(creator);
        vm.expectRevert(IFeeManager.NothingToClaim.selector);
        fm.claim(payout);
    }

    function test_claimPlatformGoesToTreasury() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, address(0));
        vm.prank(trader); // anyone may trigger it
        fm.claimPlatform();
        assertEq(treasuryAddr.balance, 5e18);
        assertEq(fm.platformBalance(), 0);
    }

    function test_accruePlatformOpenToAnyone() public {
        vm.deal(trader, 2e18);
        vm.prank(trader);
        fm.accruePlatform{value: 2e18}(token);
        assertEq(fm.platformBalance(), 2e18);
    }

    function test_hookFeeMustBeBacked() public {
        vm.prank(hook);
        vm.expectRevert(IFeeManager.Unbacked.selector);
        fm.notifyHookFee(token, trader, 1e18);

        vm.deal(address(fm), 1e18); // the hook moves USDC in through the ERC-20 interface first
        vm.prank(hook);
        fm.notifyHookFee(token, trader, 1e18);
        assertEq(fm.balances(creator), 0.5e18);
        assertEq(fm.platformBalance(), 0.5e18);
    }

    function test_hookPathNeverBindsOrMarksTraded() public {
        vm.deal(address(fm), 1e18);
        vm.prank(hook);
        fm.notifyHookFee(token, trader, 1e18);
        assertFalse(fm.hasTraded(trader));
        assertEq(fm.referrerOf(trader), address(0));
    }

    function test_hookPathPaysExistingReferrer() public {
        vm.prank(trader);
        fm.bindReferrer(referrer);
        vm.deal(address(fm), 10e18);
        vm.prank(hook);
        fm.notifyHookFee(token, trader, 10e18);
        assertEq(fm.balances(referrer), 2e18);
        assertEq(fm.platformBalance(), 3e18);
    }

    function test_onlyHookMayNotify() public {
        vm.expectRevert(IFeeManager.Unauthorized.selector);
        fm.notifyHookFee(token, trader, 1);
    }

    /// @dev Reviewer coverage (c): a self-service binding is the wallet's own decision and outranks whatever
    ///      referrer a later trade names — the trade must not be able to redirect the share.
    function test_boundReferrerSurvivesATradeNamingSomeoneElse() public {
        address other = makeAddr("other");
        vm.prank(trader);
        fm.bindReferrer(referrer);

        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, other);

        assertEq(fm.referrerOf(trader), referrer, "the original binding must stand");
        assertEq(fm.balances(referrer), 2e18, "the original referrer earns the share");
        assertEq(fm.balances(other), 0, "the named impostor earns nothing");
        assertEq(fm.platformBalance(), 3e18);
        assertTrue(fm.hasTraded(trader));
    }

    /// @dev Reviewer coverage (d): field-level assertion on `FeeAccrued`, including the `source` discriminator.
    function test_feeAccruedEventFields() public {
        vm.prank(trader);
        fm.bindReferrer(referrer);

        vm.expectEmit(true, true, true, true, address(fm));
        emit IFeeManager.FeeAccrued(token, trader, creator, referrer, 5e18, 2e18, 3e18, 0);
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, address(0));

        // Same split through the hook path, but tagged source = 1.
        vm.deal(address(fm), address(fm).balance + 10e18);
        vm.expectEmit(true, true, true, true, address(fm));
        emit IFeeManager.FeeAccrued(token, trader, creator, referrer, 5e18, 2e18, 3e18, 1);
        vm.prank(hook);
        fm.notifyHookFee(token, trader, 10e18);
    }

    // ---------------------------------------------------------------- M5: sweepUnaccounted

    function test_sweepUnaccountedCreditsTheUnowedBalanceToThePlatform() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, referrer);
        uint256 owedBefore = fm.totalOwed();
        uint256 platformBefore = fm.platformBalance();

        // A stray native transfer, or a hook `take` whose `notifyHookFee` follow-up never happened.
        vm.deal(address(fm), address(fm).balance + 4e18);

        vm.expectEmit(true, true, true, true, address(fm));
        emit IFeeManager.PlatformAccrued(address(0), trader, 4e18);
        vm.prank(trader); // permissionless
        uint256 swept = fm.sweepUnaccounted();

        assertEq(swept, 4e18);
        assertEq(fm.platformBalance(), platformBefore + 4e18);
        assertEq(fm.totalOwed(), owedBefore + 4e18);
        // Conservation still holds, and now with nothing left over.
        assertGe(address(fm).balance, fm.totalOwed());
        assertEq(address(fm).balance, fm.totalOwed());
        assertEq(fm.balances(creator) + fm.balances(referrer) + fm.platformBalance(), fm.totalOwed());
    }

    function test_sweepUnaccountedRevertsWhenNothingIsUnaccounted() public {
        vm.prank(curve);
        fm.accrueTradeFee{value: 10e18}(token, trader, referrer);
        vm.expectRevert(IFeeManager.NothingToClaim.selector);
        fm.sweepUnaccounted();
    }

    function test_sweptBalanceIsClaimableByTheTreasury() public {
        vm.deal(address(fm), 3e18);
        fm.sweepUnaccounted();
        fm.claimPlatform();
        assertEq(treasuryAddr.balance, 3e18);
        assertEq(fm.totalOwed(), 0);
    }

    function testFuzz_splitConserves(uint96 amount, bool withReferrer) public {
        vm.deal(curve, amount);
        vm.prank(curve);
        fm.accrueTradeFee{value: amount}(token, trader, withReferrer ? referrer : address(0));
        assertEq(fm.balances(creator) + fm.balances(referrer) + fm.platformBalance(), amount);
        assertEq(fm.totalOwed(), amount);
        assertEq(address(fm).balance, amount);
    }
}
