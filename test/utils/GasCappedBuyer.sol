// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondingCurve} from "../../src/BondingCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Buys through a curve with an explicit gas cap on the inner call, recording how much gas that call
///         actually consumed and what it reverted with.
/// @dev The recorded gas figure is what tells the two `InsufficientGasForGraduation` paths apart: the
///      pre-`try` floor check aborts after only the buy's own ~150k of work, while the out-of-gas
///      discriminator in the `catch` can only fire once the child call has burned everything forwarded to it
///      (EIP-150's 63/64 rule), i.e. essentially the whole cap.
contract GasCappedBuyer {
    uint256 public gasUsedByCall;
    bool public callReverted;
    bytes public revertData;

    /// @dev Re-reverts with the inner call's exact revert data, so `vm.expectRevert(selector)` can pin it.
    function buyBubbling(BondingCurve curve, uint256 value, uint256 gasLimit) external returns (uint256) {
        (bool ok, bytes memory data) = _call(curve, value, gasLimit);
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
        return abi.decode(data, (uint256));
    }

    /// @dev Swallows the revert and records the evidence (gas consumed + revert data) instead.
    function probeBuy(BondingCurve curve, uint256 value, uint256 gasLimit) external {
        (bool ok, bytes memory data) = _call(curve, value, gasLimit);
        callReverted = !ok;
        revertData = data;
    }

    function _call(BondingCurve curve, uint256 value, uint256 gasLimit) private returns (bool ok, bytes memory data) {
        bytes memory payload = abi.encodeCall(BondingCurve.buy, (0, address(0), type(uint256).max));
        uint256 g = gasleft();
        (ok, data) = address(curve).call{value: value, gas: gasLimit}(payload);
        gasUsedByCall = g - gasleft();
    }

    receive() external payable {}
}

/// @notice The C1 griefing attempt, in ONE transaction: a gas-capped buy that sells the curve out while
///         starving the in-buy graduation, immediately followed by a 1-unit sell whose proceeds are zero,
///         meant to flip the phase back to `Trading` so the permissionless `graduate()` retry never has a
///         block in which it is callable.
contract GriefingBuyer {
    bool public buyReverted;
    bool public sellReverted;

    function attack(BondingCurve curve, uint256 value, uint256 gasLimit) external {
        try curve.buy{value: value, gas: gasLimit}(0, address(0), type(uint256).max) returns (uint256) {}
        catch {
            buyReverted = true;
        }
        IERC20 t = IERC20(address(curve.token()));
        t.approve(address(curve), 1);
        try curve.sell(1, 0, address(0), type(uint256).max) returns (uint256) {}
        catch {
            sellReverted = true;
        }
    }

    receive() external payable {}
}
