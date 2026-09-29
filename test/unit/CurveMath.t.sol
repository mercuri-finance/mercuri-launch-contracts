// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurveMathHarness} from "../utils/CurveMathHarness.sol";
import {DefaultConfig} from "../../script/DefaultConfig.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";

contract CurveMathTest is Test {
    CurveMathHarness m;
    LaunchConfig cfg;

    function setUp() public {
        m = new CurveMathHarness();
        cfg = DefaultConfig.get();
    }

    function test_defaultCurveSellsOutAt18000Usdc() public view {
        uint256 cost = m.costOfTokens(cfg.virtualUsdc, cfg.virtualTokens, cfg.curveSupply);
        assertApproxEqAbs(cost, 18_000e18, 1e9);
    }

    function test_defaultCurveStartAndEndMarketCap() public view {
        // price = x / y, market cap = price * 1e9 tokens
        uint256 startCap = cfg.virtualUsdc * 1e27 / cfg.virtualTokens;
        uint256 xEnd = cfg.virtualUsdc + 18_000e18;
        uint256 yEnd = cfg.virtualTokens - cfg.curveSupply;
        uint256 endCap = xEnd * 1e27 / yEnd;
        assertApproxEqAbs(startCap, 5_625e18, 1e12);
        assertApproxEqAbs(endCap, 90_000e18, 1e12);
    }

    function test_poolSeedingNeedsExactlyTheCollectedUsdc() public view {
        uint256 xEnd = cfg.virtualUsdc + 18_000e18;
        uint256 yEnd = cfg.virtualTokens - cfg.curveSupply;
        assertApproxEqAbs(cfg.poolSupply * xEnd / yEnd, 18_000e18, 1e12);
    }

    function testFuzz_buyNeverDecreasesProduct(uint256 usdcIn) public view {
        usdcIn = bound(usdcIn, 1, 1_000_000e18);
        uint256 x = cfg.virtualUsdc;
        uint256 y = cfg.virtualTokens;
        uint256 out = m.tokensForUsdc(x, y, usdcIn);
        assertGe((x + usdcIn) * (y - out), x * y);
    }

    function testFuzz_sellNeverDecreasesProduct(uint256 sold, uint256 tokensIn) public view {
        sold = bound(sold, 1e18, cfg.curveSupply);
        tokensIn = bound(tokensIn, 1, sold);
        uint256 x = cfg.virtualUsdc + m.costOfTokens(cfg.virtualUsdc, cfg.virtualTokens, sold);
        uint256 y = cfg.virtualTokens - sold;
        uint256 out = m.usdcForTokens(x, y, tokensIn);
        assertGe((x - out) * (y + tokensIn), x * y);
    }

    function testFuzz_costOfTokensIsEnoughToBuyThem(uint256 tokensOut) public view {
        tokensOut = bound(tokensOut, 1, cfg.curveSupply);
        uint256 cost = m.costOfTokens(cfg.virtualUsdc, cfg.virtualTokens, tokensOut);
        assertGe(m.tokensForUsdc(cfg.virtualUsdc, cfg.virtualTokens, cost), tokensOut);
    }

    function testFuzz_roundTripNeverProfits(uint256 usdcIn) public view {
        usdcIn = bound(usdcIn, 1e6, 17_000e18);
        uint256 x = cfg.virtualUsdc;
        uint256 y = cfg.virtualTokens;
        uint256 out = m.tokensForUsdc(x, y, usdcIn);
        uint256 back = m.usdcForTokens(x + usdcIn, y - out, out);
        assertLe(back, usdcIn);
    }

    function test_splitBuy() public view {
        (uint256 fee, uint256 tax, uint256 net) = m.splitBuy(100e18, 100, 9_900);
        assertEq(fee, 1e18);
        assertEq(tax, 98.01e18);
        assertEq(net, 0.99e18);
        assertEq(fee + tax + net, 100e18);
    }

    function testFuzz_grossUpCoversNet(uint256 net, uint256 taxBps) public view {
        net = bound(net, 1, 1_000_000e18);
        taxBps = bound(taxBps, 0, 9_900);
        uint256 gross = m.grossUp(net, 100, taxBps);
        (,, uint256 got) = m.splitBuy(gross, 100, taxBps);
        assertGe(got, net);
    }

    function test_snipeDecay() public view {
        assertEq(m.snipeBps(9_900, 10, 0), 9_900);
        assertEq(m.snipeBps(9_900, 10, 1), 8_910);
        assertEq(m.snipeBps(9_900, 10, 5), 4_950);
        assertEq(m.snipeBps(9_900, 10, 9), 990);
        assertEq(m.snipeBps(9_900, 10, 10), 0);
        assertEq(m.snipeBps(9_900, 10, 1_000), 0);
        assertEq(m.snipeBps(9_900, 0, 0), 0);
    }
}
