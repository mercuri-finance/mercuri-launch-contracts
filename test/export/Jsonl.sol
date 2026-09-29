// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @dev Minimal JSON-lines builders for the scenario export (streamed with vm.writeLine, never accumulated).
library Jsonl {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function q(string memory s) internal pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    function a(address x) internal pure returns (string memory) {
        return q(vm.toLowercase(vm.toString(x)));
    }

    function h(bytes memory x) internal pure returns (string memory) {
        return q(vm.toString(x));
    }

    function h32(bytes32 x) internal pure returns (string memory) {
        return q(vm.toString(x));
    }

    function n(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function topics(bytes32[] memory t) internal pure returns (string memory s) {
        s = "[";
        for (uint256 i; i < t.length; i++) {
            s = string.concat(s, i == 0 ? "" : ",", h32(t[i]));
        }
        s = string.concat(s, "]");
    }

    function write(string memory path, string memory line) internal {
        vm.writeLine(path, line);
    }
}
