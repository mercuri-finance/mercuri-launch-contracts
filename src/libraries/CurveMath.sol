// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Constant-product pricing over virtual reserves. x = USDC reserve, y = token reserve.
///         Every function rounds in the curve's favour, so x * y never decreases.
/// @dev Reserves and amounts use their respective asset's base units; callers supply positive reserves and
///      enforce allocation/fee bounds. Production curve inputs use 18 decimals for both assets. Checked
///      additions/multiplications revert outside their uint256 domain; these are not saturating operations.
library CurveMath {
    uint256 internal constant BPS = 10_000;

    /// @dev Tokens received for `usdcIn`. Rounds down.
    /// @param x Virtual plus real USDC reserve before the trade.
    /// @param y Remaining virtual token reserve before the trade.
    /// @param usdcIn Net USDC entering reserves, after fees and tax.
    /// @return Token base units received.
    function tokensForUsdc(uint256 x, uint256 y, uint256 usdcIn) internal pure returns (uint256) {
        return Math.mulDiv(usdcIn, y, x + usdcIn);
    }

    /// @dev USDC received for `tokensIn`, before fees. Rounds down.
    /// @param x Virtual plus real USDC reserve before the trade.
    /// @param y Remaining virtual token reserve before the trade.
    /// @param tokensIn Token base units returned to reserves.
    /// @return Gross USDC base units, before the sell fee.
    function usdcForTokens(uint256 x, uint256 y, uint256 tokensIn) internal pure returns (uint256) {
        return Math.mulDiv(tokensIn, x, y + tokensIn);
    }

    /// @dev Smallest USDC amount that buys at least `tokensOut`. Rounds up. Requires tokensOut < y.
    /// @param x Virtual plus real USDC reserve before the trade.
    /// @param y Remaining virtual token reserve before the trade.
    /// @param tokensOut Requested token base units, strictly below y.
    /// @return Net USDC base units required, before grossing up fees and tax.
    function costOfTokens(uint256 x, uint256 y, uint256 tokensOut) internal pure returns (uint256) {
        return Math.mulDiv(x, tokensOut, y - tokensOut, Math.Rounding.Ceil);
    }

    /// @dev Splits a gross buy into trade fee, snipe tax and the net amount priced on the curve.
    /// @param gross Total USDC base units offered.
    /// @param feeBps Trade fee in basis points of gross, at most BPS.
    /// @param taxBps Snipe tax in basis points of gross minus fee, at most BPS.
    /// @return fee Trade fee, rounded down.
    /// @return tax Snipe tax on the post-fee amount, rounded down.
    /// @return net Amount entering curve reserves, including rounding remainder.
    function splitBuy(uint256 gross, uint256 feeBps, uint256 taxBps)
        internal
        pure
        returns (uint256 fee, uint256 tax, uint256 net)
    {
        fee = gross * feeBps / BPS;
        tax = (gross - fee) * taxBps / BPS;
        net = gross - fee - tax;
    }

    /// @dev A gross amount whose net (after fee and tax) is at least `net`. Requires feeBps, taxBps < BPS.
    /// @param net Required net USDC base units.
    /// @param feeBps Trade fee basis points, strictly below BPS.
    /// @param taxBps Post-fee snipe tax basis points, strictly below BPS.
    /// @return Conservative gross USDC amount; not necessarily the smallest gross amount because splitBuy rounds down.
    function grossUp(uint256 net, uint256 feeBps, uint256 taxBps) internal pure returns (uint256) {
        return Math.mulDiv(net, BPS * BPS, (BPS - feeBps) * (BPS - taxBps), Math.Rounding.Ceil);
    }

    /// @dev Linear decay from `startBps` at elapsed = 0 to zero at elapsed = snipeBlocks.
    /// @param startBps Initial tax rate in basis points.
    /// @param snipeBlocks Decay window in blocks; zero disables the tax.
    /// @param elapsed Blocks since launch, not seconds.
    /// @return Current tax basis points, rounded down; zero once the window ends.
    function snipeBps(uint256 startBps, uint256 snipeBlocks, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= snipeBlocks) return 0;
        return startBps * (snipeBlocks - elapsed) / snipeBlocks;
    }
}
