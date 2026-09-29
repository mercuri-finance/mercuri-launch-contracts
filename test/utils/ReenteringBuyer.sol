// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondingCurve} from "../../src/BondingCurve.sol";

/// @notice On receiving its native refund mid-buy, tries to re-enter the curve via `buy`, `sell` and `graduate`,
///         recording whether each attempt reverted. Used to prove the reentrancy guard holds across the refund.
contract ReenteringBuyer {
    BondingCurve public curve;
    bool public buyReverted;
    bool public sellReverted;
    bool public graduateReverted;

    function buy(BondingCurve curve_, uint256 value, uint256 minTokensOut, address referrer, uint256 deadline)
        external
        returns (uint256 out)
    {
        curve = curve_;
        out = curve_.buy{value: value}(minTokensOut, referrer, deadline);
    }

    receive() external payable {
        try curve.buy(0, address(0), type(uint256).max) returns (uint256) {}
        catch {
            buyReverted = true;
        }

        try curve.sell(0, 0, address(0), type(uint256).max) returns (uint256) {}
        catch {
            sellReverted = true;
        }

        try curve.graduate() {}
        catch {
            graduateReverted = true;
        }
    }
}
