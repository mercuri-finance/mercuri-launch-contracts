// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {AdvHandler} from "./AdvHandler.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {IFeeManager} from "../../src/interfaces/IFeeManager.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract AdvInvariantsTest is LaunchFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    AdvHandler handler;

    function setUp() public {
        _deploySystem();
        handler = new AdvHandler(factory, feeManager, gm, hook, poolManager, owner, guardian);
        targetContract(address(handler));

        bytes4[] memory s = new bytes4[](61);
        uint256 n;
        for (uint256 i; i < 5; ++i) {
            s[n++] = handler.create.selector;
        }
        for (uint256 i; i < 7; ++i) {
            s[n++] = handler.buy.selector;
        }
        for (uint256 i; i < 6; ++i) {
            s[n++] = handler.completeBuy.selector;
        }
        for (uint256 i; i < 6; ++i) {
            s[n++] = handler.sell.selector;
        }
        for (uint256 i; i < 2; ++i) {
            s[n++] = handler.retryGraduation.selector;
        }
        for (uint256 i; i < 12; ++i) {
            s[n++] = handler.poolSwap.selector;
        }
        for (uint256 i; i < 3; ++i) {
            s[n++] = handler.addLiquidity.selector;
        }
        for (uint256 i; i < 2; ++i) {
            s[n++] = handler.removeLiquidity.selector;
        }
        for (uint256 i; i < 2; ++i) {
            s[n++] = handler.donateToPool.selector;
        }
        for (uint256 i; i < 2; ++i) {
            s[n++] = handler.bindReferrer.selector;
        }
        for (uint256 i; i < 3; ++i) {
            s[n++] = handler.claim.selector;
        }
        s[n++] = handler.claimHostile.selector;
        s[n++] = handler.claimPlatform.selector;
        for (uint256 i; i < 2; ++i) {
            s[n++] = handler.sweep.selector;
        }
        s[n++] = handler.forceNative.selector;
        s[n++] = handler.donateUsdc.selector;
        s[n++] = handler.donateToken.selector;
        s[n++] = handler.setConfig.selector;
        s[n++] = handler.togglePause.selector;
        s[n++] = handler.sabotageGraduation.selector;
        s[n++] = handler.advance.selector;
        require(n == 61, "weights");
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    function invariant_adv_all() public view {
        assertEq(handler.violationCount(), 0, handler.firstViolation());

        // ---- FeeManager ledger
        assertEq(
            address(feeManager).balance,
            feeManager.totalOwed() + handler.ghostUnswept(),
            "FeeManager balance == totalOwed + tracked unswept donations"
        );
        uint256 sum = feeManager.platformBalance();
        for (uint256 i; i < handler.ledgerCount(); ++i) {
            address a = handler.ledgerAccounts(i);
            uint256 b = feeManager.balances(a);
            assertEq(b, handler.ghostBal(a), "account balance == independent model");
            sum += b;
        }
        assertEq(sum, feeManager.totalOwed(), "known balances + platform == totalOwed");
        assertEq(feeManager.platformBalance(), handler.ghostPlatform(), "platform bucket == independent model");

        // ---- referral model
        for (uint256 i; i < handler.claimantCount(); ++i) {
            address a = handler.claimants(i);
            assertEq(feeManager.referrerOf(a), handler.ghostRef(a), "referrerOf == model");
            assertEq(feeManager.hasTraded(a), handler.ghostTraded(a), "hasTraded == model");
        }

        // ---- system balances
        assertEq(address(hook).balance, 0, "hook holds no USDC");
        assertEq(address(factory).balance, 0, "factory holds no USDC");
        assertEq(address(gm).balance, handler.ghostGmDonated(), "GraduationManager holds only donations");

        // ---- curves
        for (uint256 i; i < handler.curveCount(); ++i) {
            BondingCurve c = handler.curves(i);
            LaunchToken t = c.token();
            IFeeManager.TokenInfo memory info = feeManager.tokenInfo(address(t));
            assertEq(info.curve, address(c), "registered curve");
            assertEq(factory.curveOf(address(t)), address(c), "registry");
            assertEq(info.tradeFeeBps, c.tradeFeeBps(), "fee snapshot consistent");
            assertEq(info.tradeFeeBps, handler.feeBpsOf(address(t)), "fee snapshot == config at creation");
            assertEq(info.creatorShareBps, handler.cShare(address(t)), "creator share snapshot");
            assertEq(info.referrerShareBps, handler.rShare(address(t)), "referrer share snapshot");
            assertEq(info.creator, handler.creatorOf(address(t)), "creator");

            assertEq(t.totalSupply(), 1_000_000_000e18, "supply constant");
            assertEq(t.balanceOf(address(hook)), 0, "hook holds no tokens");
            assertEq(
                address(c).balance,
                c.realUsdc() + handler.ghostCurveDonated(address(c)),
                "curve balance == realUsdc + donations"
            );
            uint256 donatedTok = handler.ghostCurveTokenDonated(address(c));
            if (c.phase() != BondingCurve.Phase.Graduated) {
                uint256 x = c.virtualUsdc() + c.realUsdc();
                uint256 y = c.virtualTokens() - c.sold();
                assertLe(CurveMath.usdcForTokens(x, y, c.sold()), c.realUsdc(), "full exit payable");
                assertGe(x * y, c.virtualUsdc() * c.virtualTokens(), "k >= k0");
                assertLe(c.sold(), c.curveSupply());
                assertEq(
                    t.balanceOf(address(c)),
                    c.poolSupply() + c.curveSupply() - c.sold() + donatedTok,
                    "curve token balance"
                );
            } else {
                assertEq(c.realUsdc(), 0);
                assertEq(c.sold(), c.curveSupply());
                assertEq(t.balanceOf(address(c)), donatedTok, "graduated curve holds no protocol tokens");
                assertTrue(locker.isLocked(address(t)), "locked");
                uint256 locked = handler.lockedLiq(address(t));
                assertGt(locked, 0);
                assertEq(posm.getPositionLiquidity(locker.positionOf(address(t))), locked, "locked liquidity unchanged");
                assertGe(poolManager.getLiquidity(gm.poolKey(address(t)).toId()), locked, "pool liquidity >= locked");
            }
        }
    }

    function afterInvariant() public {
        vm.clearMockedCalls();
        vm.writeLine("test-export/adv-stats.csv", handler.statsCsv());
    }
}
