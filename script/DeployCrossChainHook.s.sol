// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrossChainSwapHook} from "../src/CrossChainSwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract DeployCrossChainHook is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address pythOracle = vm.envAddress("PYTH_ORACLE");
        address bridgeProtocol = vm.envAddress("BRIDGE_PROTOCOL");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast(deployerPrivateKey);

        CrossChainSwapHook hook = new CrossChainSwapHook(
            IPoolManager(poolManager),
            pythOracle,
            bridgeProtocol,
            feeRecipient
        );

        console.log("CrossChainSwapHook deployed at:", address(hook));
        console.log("Hook permissions:", _getHookPermissionsString(hook.getHookPermissions()));

        vm.stopBroadcast();
    }

    function _getHookPermissionsString(Hooks.Permissions memory permissions) 
        internal 
        pure 
        returns (string memory) 
    {
        return string(abi.encodePacked(
            "beforeSwap: ", permissions.beforeSwap ? "true" : "false", ", ",
            "afterSwap: ", permissions.afterSwap ? "true" : "false"
        ));
    }
}
