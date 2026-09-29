// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondingCurve} from "../../src/BondingCurve.sol";

/// @notice Has no `receive`/`fallback`: any native transfer sent to it reverts. Used to exercise the
///         BondingCurve refund path's failure mode.
contract RejectingBuyer {
    function buy(BondingCurve curve, uint256 value, uint256 minTokensOut, address referrer, uint256 deadline)
        external
        returns (uint256)
    {
        return curve.buy{value: value}(minTokensOut, referrer, deadline);
    }
}
