// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";

/// @dev Deploys each proxied contract as the deploy flow does: implementation first, then an `ERC1967Proxy`
///      initialised in its constructor. Every function is `internal`, so both CREATEs come from the calling
///      contract (implementation at its nonce N, proxy at N + 1), which keeps address prediction simple.
library Proxies {
    function feeManager(address factory_, address hook_, address graduationManager_, address owner_)
        internal
        returns (FeeManager)
    {
        address impl = address(new FeeManager());
        bytes memory init = abi.encodeCall(FeeManager.initialize, (factory_, hook_, graduationManager_, owner_));
        return FeeManager(address(new ERC1967Proxy(impl, init)));
    }

    function graduationManager(
        address factory_,
        address poolManager_,
        address positionManager_,
        address permit2_,
        address hook_,
        address locker_,
        address feeManager_,
        address usdc_,
        address owner_
    ) internal returns (GraduationManager) {
        address impl = address(new GraduationManager());
        bytes memory init = abi.encodeCall(
            GraduationManager.initialize,
            (factory_, poolManager_, positionManager_, permit2_, hook_, locker_, feeManager_, usdc_, owner_)
        );
        return GraduationManager(address(new ERC1967Proxy(impl, init)));
    }

    function launchFactory(
        address owner_,
        address guardian_,
        address treasury_,
        address feeManager_,
        address graduationManager_,
        LaunchConfig memory cfg
    ) internal returns (LaunchFactory) {
        address impl = address(new LaunchFactory());
        bytes memory init = abi.encodeCall(
            LaunchFactory.initialize, (owner_, guardian_, treasury_, feeManager_, graduationManager_, cfg)
        );
        return LaunchFactory(address(new ERC1967Proxy(impl, init)));
    }
}
