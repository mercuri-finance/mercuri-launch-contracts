// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchConfig} from "../src/libraries/LaunchTypes.sol";

library DefaultConfig {
    function get() internal pure returns (LaunchConfig memory) {
        return LaunchConfig({
            virtualUsdc: 6_000e18,
            virtualTokens: uint256(3_200_000_000e18) / 3,
            curveSupply: 800_000_000e18,
            poolSupply: 200_000_000e18,
            launchFee: 1e18,
            maxInitialBuyTokens: 50_000_000e18,
            tradeFeeBps: 100,
            creatorShareBps: 5_000,
            referrerShareBps: 2_000,
            snipeStartBps: 9_900,
            snipeBlocks: 120 // ~60 s at Arc's ~0.5 s blocks
        });
    }
}
