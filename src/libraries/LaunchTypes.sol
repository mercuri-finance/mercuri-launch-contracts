// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Parameters every new launch is created with. Snapshotted into the curve at deployment.
struct LaunchConfig {
    /// @notice Initial virtual native USDC reserve in 18-decimal wei; positive.
    uint256 virtualUsdc;
    /// @notice Initial virtual tokens in 18-decimal units; greater than curveSupply.
    uint256 virtualTokens;
    /// @notice Tokens sold on the curve in 18-decimal units; together with poolSupply equals one billion tokens.
    uint256 curveSupply;
    /// @notice Positive allocation reserved for the pool, in 18-decimal token units.
    uint256 poolSupply;
    /// @notice Native USDC wei charged per launch (18 decimals); factory caps at 100 USDC.
    uint256 launchFee;
    /// @notice Deployer's tax-exempt initial-buy token cap in 18-decimal units; at most curveSupply.
    uint256 maxInitialBuyTokens;
    /// @notice Fee rate in bps of the USDC leg; current factory policy caps at 500 (5%).
    uint16 tradeFeeBps;
    /// @notice Creator share in bps of the fee, not trade value; combined shares must be <= 10,000.
    uint16 creatorShareBps;
    /// @notice Referrer share in bps of the fee; unbound referrals leave this share with the platform.
    uint16 referrerShareBps;
    /// @notice Initial buy tax in bps of value after the trade fee; capped at 9,900.
    uint16 snipeStartBps;
    /// @notice Linear decay duration in blocks, capped at 1,200; zero disables the tax.
    uint32 snipeBlocks;
}

/// @notice Caller-supplied launch metadata, recipients and salt.
/// @dev Name, symbol, metadataURI and salt affect CREATE2 predictions; creator and referrer do not.
struct CreateParams {
    /// @notice Token name, 1 to 32 bytes; UTF-8 validity is not checked on-chain.
    string name;
    /// @notice Token symbol, 1 to 10 bytes; UTF-8 validity is not checked on-chain.
    string symbol;
    /// @notice Permanent metadata reference, at most 256 bytes; content validity is an off-chain concern.
    string metadataURI;
    /// @notice Nonzero creator-fee recipient; need not equal the deployer.
    address creator;
    /// @notice Optional referral considered for the deployer's initial buy; no binding occurs without a buy.
    address referrer;
    /// @notice Salt scoped to msg.sender by the factory; identical init code and salt cannot deploy twice.
    bytes32 salt;
}
