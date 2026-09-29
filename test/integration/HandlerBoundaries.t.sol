// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GovernedFixture} from "../utils/GovernedFixture.sol";
import {Handler} from "../invariant/Handler.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @dev The stress harness must normalize arbitrary seeds before offsetting actor indices.
contract HandlerBoundariesTest is GovernedFixture {
    Handler internal handler;

    function setUp() public {
        _deployGoverned();
        handler = new Handler(factory, feeManager, gm, new PoolSwapTest(poolManager));
    }

    function test_createAndBuyAcceptMaxActorSeed() public {
        handler.create(type(uint256).max, 100e18);
        assertEq(handler.curveCount(), 1);
        BondingCurve c = handler.curves(0);
        uint256 soldBefore = c.sold();
        handler.buy(0, type(uint256).max, 2_000e18);
        assertGt(c.sold(), soldBefore, "maximum seed executes a real buy");
    }

    function test_sellAndPoolSwapWrapMaxActorSeed() public {
        handler.create(0, 100e18);
        BondingCurve c = handler.curves(0);
        uint256 soldBefore = c.sold();
        // Actor 3 (max % 4) has no tokens; the search must wrap to funded actor 0.
        handler.sell(0, type(uint256).max, 5_000);
        assertLt(c.sold(), soldBefore, "actor search executes a real sell");
        handler.completeCurve(0, 0);
        handler.retryGraduation(0);
        assertEq(uint256(c.phase()), uint256(BondingCurve.Phase.Graduated));
        handler.poolSwap(0, type(uint256).max, false, false, 1e18);
        assertEq(handler.exactInSells(), 1, "actor search executes a real pool sell");
    }
}
