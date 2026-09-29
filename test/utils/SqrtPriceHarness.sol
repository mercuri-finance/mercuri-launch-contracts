// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GraduationManager} from "../../src/GraduationManager.sol";

/// @dev Test-only harness exposing `GraduationManager._sqrtPriceX96` (internal) for direct unit/fuzz testing,
///      without duplicating its numerics — reusing the inherited function body avoids any risk of the test
///      drifting from what actually ships. Never initialised (the inherited constructor disables initializers):
///      nothing here ever calls `graduate` or touches any of the wired-up addresses.
contract SqrtPriceHarness is GraduationManager {
    function sqrtPriceX96(uint256 amount0, uint256 amount1) external pure returns (uint160) {
        return _sqrtPriceX96(amount0, amount1);
    }
}
