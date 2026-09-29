// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGraduationManager} from "../../src/interfaces/IGraduationManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockGraduationManager is IGraduationManager {
    bool public shouldRevert;
    /// @dev Gas this mock burns before doing anything else, so a gas-starved in-buy graduation can be
    ///      reproduced deterministically at unit level without the real Uniswap stack's ~640k of work. Set it
    ///      above anything that could be forwarded and the call always runs out of gas.
    uint256 public gasToBurn;
    uint256 public burnSink;
    uint256 public receivedUsdc;
    uint256 public receivedTokens;
    uint256 public calls;

    function setShouldRevert(bool v) external { shouldRevert = v; }

    function setGasToBurn(uint256 v) external { gasToBurn = v; }

    function graduate(address token) external payable {
        require(!shouldRevert, "mock: graduation failed");
        uint256 burn = gasToBurn;
        if (burn != 0) {
            uint256 remaining = gasleft();
            uint256 target = remaining > burn ? remaining - burn : 0;
            uint256 spins;
            // Runs out of gas outright when `burn` exceeds what was forwarded, which is the point.
            while (gasleft() > target) {
                unchecked {
                    ++spins;
                }
            }
            burnSink = spins;
        }
        receivedUsdc = msg.value;
        receivedTokens = IERC20(token).balanceOf(address(this));
        ++calls;
    }
}
