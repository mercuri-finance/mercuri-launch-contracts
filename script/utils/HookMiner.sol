// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Finds a CREATE2 salt whose resulting address carries exactly the given Uniswap v4 hook flag bits.
library HookMiner {
    uint160 private constant FLAG_MASK = uint160((1 << 14) - 1);
    uint256 private constant MAX_LOOP = 500_000;

    error SaltNotFound();

    function find(address deployer, uint160 flags, bytes memory creationCodeWithArgs)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        bytes32 initHash = keccak256(creationCodeWithArgs);
        for (uint256 i; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(hook) & FLAG_MASK == flags && hook.code.length == 0) return (hook, salt);
        }
        revert SaltNotFound();
    }
}
