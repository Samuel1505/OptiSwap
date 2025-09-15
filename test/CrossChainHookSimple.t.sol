// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CrossChainSwapHook} from "../src/CrossChainSwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract CrossChainHookSimpleTest is Test {
    CrossChainSwapHook public hook;
    IPoolManager public poolManager;
    
    address public constant PYTH_ORACLE = address(0x123);
    address public constant BRIDGE_PROTOCOL = address(0x456);
    address public constant FEE_RECIPIENT = address(0x789);
    
    address public constant TOKEN0 = address(0x1000);
    address public constant TOKEN1 = address(0x2000);
    
    function setUp() public {
        // Deploy mock pool manager
        poolManager = IPoolManager(address(0x999));
        
        // Deploy the hook without validation (for testing only)
        vm.etch(address(0x1234567890123456789012345678901234567890), "");
        vm.startPrank(address(0x1234567890123456789012345678901234567890));
        
        // Create a mock hook that doesn't validate address
        hook = new CrossChainSwapHook(
            poolManager,
            PYTH_ORACLE,
            BRIDGE_PROTOCOL,
            FEE_RECIPIENT
        );
        
        vm.stopPrank();
    }
    
    function testHookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
    }
    
    function testAddVenue() public {
        uint256 chainId = 137;
        address venueAddress = address(0x3000);
        string memory name = "Polygon Uniswap";
        uint256 gasEstimate = 200000;
        
        hook.addVenue(chainId, venueAddress, name, gasEstimate);
        
        CrossChainSwapHook.SwapVenue memory venue = hook.getVenueInfo(1);
        
        assertEq(venue.chainId, chainId);
        assertEq(venue.venueAddress, venueAddress);
        assertEq(venue.name, name);
        assertTrue(venue.isActive);
        assertEq(venue.baseGasEstimate, gasEstimate);
    }
    
    function testConfigurePriceData() public {
        address token = TOKEN0;
        bytes32 priceId = keccak256("ETH_PRICE_ID");
        uint256 maxStaleness = 600;
        
        hook.configurePriceData(token, priceId, maxStaleness);
        
        CrossChainSwapHook.PriceData memory priceData = hook.getTokenPriceData(token);
        
        assertEq(priceData.priceId, priceId);
        assertEq(priceData.maxStaleness, maxStaleness);
        assertTrue(priceData.isActive);
    }
    
    function testUpdateSwapParameters() public {
        uint256 maxSlippageBps = 500;
        uint256 bridgeSlippageBps = 200;
        uint256 minBridgeAmount = 200e18;
        uint256 crossChainThresholdBps = 300;
        
        hook.updateSwapParameters(maxSlippageBps, bridgeSlippageBps, minBridgeAmount, crossChainThresholdBps);
        
        assertEq(hook.maxSlippageBps(), maxSlippageBps);
        assertEq(hook.bridgeSlippageBps(), bridgeSlippageBps);
        assertEq(hook.minBridgeAmount(), minBridgeAmount);
        assertEq(hook.crossChainThresholdBps(), crossChainThresholdBps);
    }
    
    function testPauseUnpause() public {
        assertFalse(hook.paused());
        
        hook.pause();
        assertTrue(hook.paused());
        
        hook.unpause();
        assertFalse(hook.paused());
    }
    
    function testOnlyOwnerFunctions() public {
        address nonOwner = address(0x9999);
        
        vm.startPrank(nonOwner);
        
        vm.expectRevert();
        hook.addVenue(137, address(0x3000), "Test", 200000);
        
        vm.expectRevert();
        hook.configurePriceData(TOKEN0, keccak256("TEST"), 600);
        
        vm.expectRevert();
        hook.updateSwapParameters(500, 200, 200e18, 300);
        
        vm.expectRevert();
        hook.pause();
        
        vm.stopPrank();
    }
    
    function testGetAllActiveVenues() public {
        // Add multiple venues
        hook.addVenue(137, address(0x3000), "Polygon", 200000);
        hook.addVenue(42161, address(0x4000), "Arbitrum", 150000);
        
        // Deactivate one venue
        hook.updateVenueStatus(1, false);
        
        // Get active venues
        CrossChainSwapHook.SwapVenue[] memory activeVenues = hook.getAllActiveVenues();
        
        // Should have 2 active venues (index 0 is local, index 2 is Arbitrum)
        assertEq(activeVenues.length, 2);
        assertEq(activeVenues[0].chainId, block.chainid); // Local venue
        assertEq(activeVenues[1].chainId, 42161); // Arbitrum venue
    }
    
    function testIsChainSupported() public view {
        assertTrue(hook.isChainSupported(block.chainid)); // Local chain should be supported
        
        // Note: We can't test other chains without adding venues first
        assertFalse(hook.isChainSupported(999)); // Random chain should not be supported
    }
}
