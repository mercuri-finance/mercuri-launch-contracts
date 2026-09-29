// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScenarioBase} from "./ScenarioBase.sol";

contract Sink {
    event Got(uint256 v);

    receive() external payable {
        emit Got(msg.value);
    }
}

contract ExportSmokeTest is ScenarioBase {
    function test_exportWritesMirrorsInOrder() public {
        _deployV4();
        _begin("smoke");
        Sink s = new Sink();
        known.push(address(s));
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 10e18);
        _openBlock(100, 1_700_000_000);
        _call(buyer, address(s), 1e18, "");
        _finish();
        string memory chain = vm.readFile(string.concat(dir, "chain.jsonl"));
        // block, tx, mirror (value to the sink, before the sink's own log), the sink's log
        assertTrue(vm.contains(chain, '"li":0,"tx"'));
        assertTrue(vm.contains(chain, '"addr":"0xfffffffffffffffffffffffffffffffffffffffe","topics"'));
        assertTrue(vm.contains(chain, '"li":1'));
    }
}
