// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurveMath} from "../../src/libraries/CurveMath.sol";

contract CurveMathHarness {
    function tokensForUsdc(uint256 x, uint256 y, uint256 a) external pure returns (uint256) { return CurveMath.tokensForUsdc(x, y, a); }
    function usdcForTokens(uint256 x, uint256 y, uint256 a) external pure returns (uint256) { return CurveMath.usdcForTokens(x, y, a); }
    function costOfTokens(uint256 x, uint256 y, uint256 a) external pure returns (uint256) { return CurveMath.costOfTokens(x, y, a); }
    function splitBuy(uint256 g, uint256 f, uint256 t) external pure returns (uint256, uint256, uint256) { return CurveMath.splitBuy(g, f, t); }
    function grossUp(uint256 n, uint256 f, uint256 t) external pure returns (uint256) { return CurveMath.grossUp(n, f, t); }
    function snipeBps(uint256 s, uint256 b, uint256 e) external pure returns (uint256) { return CurveMath.snipeBps(s, b, e); }
}
