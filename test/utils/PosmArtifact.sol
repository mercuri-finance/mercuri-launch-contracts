// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Forces Uniswap's PositionManager to be compiled so V4Fixture can deploy it from its artifact.
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
