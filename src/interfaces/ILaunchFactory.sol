// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILaunchFactory {
    /// @notice Returns the authentic curve registered for a launch.
    /// @param token Launch token to query.
    /// @return Curve address, or zero for an unregistered token.
    function curveOf(address token) external view returns (address);
    /// @notice Returns the current recipient of platform claims; governance may change it.
    /// @return Treasury address.
    function treasury() external view returns (address);
}
