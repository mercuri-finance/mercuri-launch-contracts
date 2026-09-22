// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply ERC-20. The whole supply is minted once to the deployer (the bonding curve).
///         No owner, no mint, no burn, no pause, no blocklist, no transfer tax, no proxy.
contract LaunchToken is ERC20 {
    /// @notice Fixed supply: one billion tokens in 18-decimal base units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Permanent metadata reference; stored once in the constructor with no setter.
    /// @dev Referenced off-chain content is not enforced by this contract; integrators must verify its hash.
    string public metadataURI;

    /// @notice Mints the entire fixed supply to the deploying curve.
    /// @param name_ ERC-20 display name; factory validates length.
    /// @param symbol_ ERC-20 display symbol; factory validates length.
    /// @param metadataURI_ Permanent reference to launch metadata; factory validates length.
    constructor(string memory name_, string memory symbol_, string memory metadataURI_) ERC20(name_, symbol_) {
        metadataURI = metadataURI_;
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
