// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeManager} from "../../../src/FeeManager.sol";
import {ILaunchFactory} from "../../../src/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "../../../src/interfaces/IFeeManager.sol";

/// @dev V2 upgrade test double for FeeManager. Inherits it verbatim: no function is overridden, so every
///      balance, `platformBalance`, `totalOwed`, referral binding, `hasTraded` flag and `tokenInfo` is read and
///      written by the SAME production code before and after the upgrade. The only addition is one appended
///      field on the SAME namespaced struct, reached at the SAME slot.
/// @dev `FeeManager.FEE_MANAGER_STORAGE_LOCATION` is `private`, so a derived contract cannot see it; this
///      redeclares the identical constant (same formula, same value) rather than changing that visibility in
///      production. `test/upgrade/Upgrades.t.sol` pins that both constants are in fact equal (by observing that
///      writes through the base contract are visible through this contract's own accessor).
contract FeeManagerV2Mock is FeeManager {
    /// @custom:storage-location erc7201:launchpad.storage.FeeManager
    struct FeeManagerV2Storage {
        ILaunchFactory factory;
        address hook;
        address graduationManager;
        mapping(address token => IFeeManager.TokenInfo) tokens;
        mapping(address account => uint256) balances;
        mapping(address trader => address) referrerOf;
        mapping(address trader => bool) hasTraded;
        uint256 platformBalance;
        uint256 totalOwed;
        uint256 extraField; // NEW in V2: appended after every V1 field; nothing ever writes it
    }

    // keccak256(abi.encode(uint256(keccak256("launchpad.storage.FeeManager")) - 1)) & ~bytes32(uint256(0xff))
    // Identical value to FeeManager's own (private) FEE_MANAGER_STORAGE_LOCATION.
    bytes32 private constant FEE_MANAGER_V2_STORAGE_LOCATION =
        0xc06a3792578c68935c12bd26baefb14bec09a70b6ceafb53cf611fda2f4dc100;

    function _s2() private pure returns (FeeManagerV2Storage storage $) {
        assembly {
            $.slot := FEE_MANAGER_V2_STORAGE_LOCATION
        }
    }

    /// @notice Reads as zero for every FeeManager upgraded from V1: nothing has ever written to it. A future
    ///         V3 would add a setter; this V2 is read-only on purpose.
    function extraField() external view returns (uint256) {
        return _s2().extraField;
    }
}
