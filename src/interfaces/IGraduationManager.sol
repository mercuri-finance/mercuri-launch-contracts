// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IGraduationManager {
    /// @notice Called by a token's curve with `poolSupply` tokens already transferred in and the USDC as msg.value.
    /// @dev Only the factory-registered curve may call. Creates the pool and permanently locks its position.
    ///      msg.value uses 18-decimal native units; seeding converts to 6-decimal ERC-20 units.
    /// @param token Launch token to graduate.
    function graduate(address token) external payable;
}
