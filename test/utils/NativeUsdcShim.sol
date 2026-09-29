// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @dev Test-only stand-in for Arc's USDC ERC-20 interface at 0x3600…0000. On Arc the 6-decimal ERC-20 balance
///      and the 18-decimal native balance are one balance. Native value moves through
///      EVM-journaled CREATE/selfdestruct, so even nested reverted transfers roll back.
///      vm.prank selects the debited account; no recipient code is called. Test-only:
///      helper creation affects gas/nonces and does not model Arc issuer controls.
contract NativeUsdcShim {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SCALE = 1e12;

    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external pure returns (string memory) {
        return "USDC";
    }

    function symbol() external pure returns (string memory) {
        return "USDC";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function balanceOf(address a) external view returns (uint256) {
        return a.balance / SCALE;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        uint256 amount = value * SCALE;
        require(from.balance >= amount, "USDC: balance");
        require(to != address(0), "USDC: zero address");
        if (amount != 0 && from != to) {
            // Foundry 1.4.3 requires nested pranks to match the active prank mode.
            (VmSafe.CallerMode mode,,) = vm.readCallers();
            if (mode == VmSafe.CallerMode.RecurrentPrank) {
                vm.startPrank(from);
                new NativeUsdcMove{value: amount}(payable(to));
                vm.stopPrank();
            } else {
                vm.prank(from);
                new NativeUsdcMove{value: amount}(payable(to));
            }
        }
        emit Transfer(from, to, value);
    }
}

/// @dev Created and destroyed in the same call. SELFDESTRUCT credits even contracts
///      without receive(), without invoking callbacks, and is reverted by the EVM.
contract NativeUsdcMove {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}
