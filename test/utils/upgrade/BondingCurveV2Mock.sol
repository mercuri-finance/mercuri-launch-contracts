// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondingCurve} from "../../../src/BondingCurve.sol";
import {LaunchConfig} from "../../../src/libraries/LaunchTypes.sol";

/// @dev The curve embedded by `LaunchFactoryV2Mock`: byte-identical to `BondingCurve` (inherited, not
///      reimplemented, so every rule, event and error is the production one) plus a `version()` marker so a
///      test can tell a curve deployed by the upgraded factory apart from one deployed before the upgrade.
///      Deliberately the ONLY addition (see the U2 report for the size trade-off this embeds into the factory).
contract BondingCurveV2Mock is BondingCurve {
    constructor(
        LaunchConfig memory cfg,
        string memory name_,
        string memory symbol_,
        string memory metadataURI_,
        address feeManager_,
        address graduationManager_
    ) BondingCurve(cfg, name_, symbol_, metadataURI_, feeManager_, graduationManager_) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}
