// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Routing shapes the indexer must attribute (§3.5). Each wraps PoolSwapTest and only routes.
abstract contract RouterBase {
    PoolSwapTest public immutable swapper;

    constructor(PoolSwapTest s) {
        swapper = s;
    }

    function _in(PoolKey memory key, SwapParams memory p) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(p.zeroForOne ? key.currency0 : key.currency1));
    }

    function _out(PoolKey memory key, SwapParams memory p) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(p.zeroForOne ? key.currency1 : key.currency0));
    }

    /// @dev Exact input only: pulls the input from the caller and swaps from this contract.
    function _pullAndSwap(PoolKey memory key, SwapParams memory p, bytes memory hookData) internal {
        require(p.amountSpecified < 0, "exact input only");
        IERC20 input = _in(key, p);
        require(input.transferFrom(msg.sender, address(this), uint256(-p.amountSpecified)), "pull");
        if (input.allowance(address(this), address(swapper)) == 0) input.approve(address(swapper), type(uint256).max);
        swapper.swap(key, p, PoolSwapTest.TestSettings(false, false), hookData);
    }

    function _send(IERC20 t, address to, uint256 amount) internal {
        if (amount != 0) require(t.transfer(to, amount), "send");
    }
}

/// @notice A forwarding hop: the pool pays this router, which passes the whole output on to `to`.
contract ForwardingRouter is RouterBase {
    constructor(PoolSwapTest s) RouterBase(s) {}

    function swapAndForward(PoolKey calldata key, SwapParams calldata p, bytes calldata hookData, address to) external {
        _pullAndSwap(key, p, hookData);
        IERC20 out = _out(key, p);
        _send(out, to, out.balanceOf(address(this)));
    }
}

/// @notice Two swaps of one pool in one transaction; the outputs return to the caller.
contract DoubleSwapRouter is RouterBase {
    constructor(PoolSwapTest s) RouterBase(s) {}

    function swapTwice(PoolKey calldata key, SwapParams calldata p1, SwapParams calldata p2, bytes calldata hookData) external {
        _pullAndSwap(key, p1, hookData);
        _pullAndSwap(key, p2, hookData);
        IERC20 a = _out(key, p1);
        _send(a, msg.sender, a.balanceOf(address(this)));
        IERC20 b = _out(key, p2);
        _send(b, msg.sender, b.balanceOf(address(this)));
    }
}

/// @notice One swap whose output is split between two recipients: attribution is ambiguous (falls back to tx.from).
contract SplitRouter is RouterBase {
    constructor(PoolSwapTest s) RouterBase(s) {}

    function swapAndSplit(PoolKey calldata key, SwapParams calldata p, bytes calldata hookData, address to1, address to2) external {
        _pullAndSwap(key, p, hookData);
        IERC20 out = _out(key, p);
        uint256 bal = out.balanceOf(address(this));
        _send(out, to1, bal / 2);
        _send(out, to2, bal - bal / 2);
    }
}

/// @notice A contract account that trades for its owner (the trader is not tx.from).
contract SmartAccount {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "call failed");
        return ret;
    }

    receive() external payable {}
}
