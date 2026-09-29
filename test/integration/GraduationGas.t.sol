// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

contract GraduationGasTest is LaunchFixture {
    function setUp() public {
        _deploySystem();
    }

    /// @dev Pins the exact self-call used by the final buy below its immutable 1M floor.
    ///      Includes the repaired shim's helper-creation overhead. Not an Arc gas measurement.
    function test_inlineGraduationFitsNinetyPercentOfFloorBothOrderings() public {
        for (uint256 i; i < 2; ++i) {
            (LaunchToken token, BondingCurve curve) = _createOrdered(i == 0);
            vm.mockCallRevert(address(gm), abi.encodeWithSelector(gm.graduate.selector), bytes("prepare pending"));
            vm.prank(bob);
            curve.buy{value: 30_000e18}(0, address(0), type(uint256).max);
            vm.clearMockedCalls();
            assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.GraduationPending));
            assertEq(curve.GRADUATION_GAS_FLOOR(), 1_000_000);
            // Cold dependencies make this conservative relative to the warmed inline path.
            address[10] memory peers = [
                address(curve),
                address(token),
                address(gm),
                address(factory),
                address(posm),
                address(poolManager),
                address(permit2),
                address(hook),
                address(locker),
                USDC
            ];
            for (uint256 j; j < peers.length; ++j) {
                vm.cool(peers[j]);
            }
            vm.cool(address(feeManager));
            vm.prank(address(curve));
            curve.executeGraduation{gas: 900_000}();
            assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
            assertTrue(locker.isLocked(address(token)));
        }
    }
}
