// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {NativeUsdcShim} from "./NativeUsdcShim.sol";

/// @dev Local stand-in for the Uniswap v4 + USDC environment that already exists on Arc.
abstract contract V4Fixture is Test, DeployPermit2 {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;

    IPoolManager internal poolManager;
    IPositionManager internal posm;
    IAllowanceTransfer internal permit2;

    function _deployV4() internal {
        vm.etch(USDC, address(new NativeUsdcShim()).code);
        poolManager = IPoolManager(address(new PoolManager(address(this))));
        permit2 = IAllowanceTransfer(deployPermit2());
        // Deployed from its artifact (see PosmArtifact.sol): PositionManager only fits the code-size limit under
        // its own low-runs compiler profile, which v4-core's Pool library cannot be compiled with.
        posm = IPositionManager(
            deployCode(
                "PositionManager.sol:PositionManager",
                abi.encode(poolManager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
            )
        );
    }
}
