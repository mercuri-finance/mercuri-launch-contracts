// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeManager} from "../../../src/FeeManager.sol";
import {GraduationManager} from "../../../src/GraduationManager.sol";
import {LaunchFactory} from "../../../src/LaunchFactory.sol";

/// @dev `script/check-storage.sh` reads these, never the production contracts directly.
///      Each proxied contract keeps its whole state inside one ERC-7201 namespaced struct that is reached
///      through an inline-assembly accessor (`_s()`), never through an actual declared state variable — so
///      `forge inspect <Contract> storageLayout` reports an EMPTY layout for FeeManager, GraduationManager and
///      LaunchFactory themselves (solc only emits "types" entries for structs that back a real declared state
///      variable; confirmed the same is true of OpenZeppelin's own upgradeable contracts, e.g.
///      `OwnableUpgradeable`, which uses the identical pattern). Declaring one throwaway state variable of each
///      namespaced struct type here, purely for introspection, is what actually exposes the struct's member
///      list (label, offset, slot, type) in `forge inspect`'s "types" section. This file is never deployed and
///      never imported by anything except the checker's own reads.
contract FeeManagerLayoutProbe {
    FeeManager.FeeManagerStorage internal probe;
}

contract GraduationManagerLayoutProbe {
    GraduationManager.GraduationManagerStorage internal probe;
}

contract LaunchFactoryLayoutProbe {
    LaunchFactory.LaunchFactoryStorage internal probe;
}
