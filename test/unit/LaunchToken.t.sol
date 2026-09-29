// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;

    function setUp() public {
        token = new LaunchToken("Example", "EX", "https://example.invalid/meta.json");
    }

    function test_metadata() public view {
        assertEq(token.name(), "Example");
        assertEq(token.symbol(), "EX");
        assertEq(token.decimals(), 18);
        assertEq(token.metadataURI(), "https://example.invalid/meta.json");
    }

    function test_entireSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000e18);
    }

    function test_noPrivilegedSurface() public {
        // None of these selectors may exist on the token.
        bytes4[6] memory banned = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("blacklist(address)")),
            bytes4(keccak256("setMetadataURI(string)"))
        ];
        for (uint256 i; i < banned.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(banned[i], address(1), 1));
            assertFalse(ok);
        }
    }

    function test_transfersAreFeeless() public {
        address a = makeAddr("a");
        token.transfer(a, 1_000e18);
        assertEq(token.balanceOf(a), 1_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
