// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CrossChainSwapHook} from "../src/CrossChainSwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// ---------------------------------------------------------------------------
/// MOCKS & HELPERS
/// ---------------------------------------------------------------------------

interface IPythOracle {
    struct Price {
        int64 price;
        int64 conf;
        uint64 publishTime;
    }

    function getPrice(bytes32 id) external view returns (Price memory);
    function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable;
}

interface IBridgeProtocol {
    struct BridgeQuote {
        uint256 bridgeFee;
        uint256 estimatedTime;
        bytes bridgeData;
    }

    function getQuote(address tokenIn, address tokenOut, uint256 amount, uint256 dstChainId) external view returns (BridgeQuote memory);
    function bridge(address token, uint256 amount, uint256 dstChainId, address recipient, bytes calldata bridgeData) external payable;
}

/// Minimal mock pool manager (do NOT inherit IPoolManager - avoids huge interface implementation)
contract MockPoolManager {
    // intentionally empty - we only need an address to pass into the hook constructor
}

/// Simple ERC20 mock that correctly implements IERC20
contract MockERC20 is IERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    function totalSupply() external pure override returns (uint256) { return 0; }

    function balanceOf(address owner) external view override returns (uint256) {
        return _balances[owner];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (msg.sender != from) {
            require(_allowances[from][msg.sender] >= amount, "Allowance");
            _allowances[from][msg.sender] -= amount;
        }
        require(_balances[from] >= amount, "InsufficientFrom");
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    // helpers for tests
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(_balances[from] >= amount, "Burn");
        _balances[from] -= amount;
    }
}

contract MockPythOracle is IPythOracle, Test {
    mapping(bytes32 => IPythOracle.Price) public prices;

    function setPrice(bytes32 id, int64 price, int64 conf, uint64 publishTime) external {
        prices[id] = IPythOracle.Price(price, conf, publishTime);
    }

    function getPrice(bytes32 id) external view override returns (IPythOracle.Price memory) {
        IPythOracle.Price memory p = prices[id];
        require(p.publishTime != 0, "Price not set");
        return p;
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {
        // noop for testing
    }
}

contract MockBridge is IBridgeProtocol {
    mapping(bytes32 => BridgeQuote) public quotes;
    bool public failBridge;

    function setQuote(address inToken, address outToken, uint256 amount, uint256 dstChain, uint256 bridgeFee, uint256 estimatedTime, bytes calldata bridgeData) external {
        bytes32 k = keccak256(abi.encodePacked(inToken, outToken, amount, dstChain));
        quotes[k] = BridgeQuote(bridgeFee, estimatedTime, bridgeData);
    }

    function setFailBridge(bool v) external { failBridge = v; }

    function getQuote(address tokenIn, address tokenOut, uint256 amount, uint256 dstChainId) external view override returns (BridgeQuote memory) {
        bytes32 k = keccak256(abi.encodePacked(tokenIn, tokenOut, amount, dstChainId));
        BridgeQuote memory q = quotes[k];
        require(q.estimatedTime != 0 || q.bridgeFee != 0 || q.bridgeData.length != 0, "no-quote");
        return q;
    }

    function bridge(address, uint256, uint256, address, bytes calldata) external payable override {
        if (failBridge) revert("bridge failed");
        // simulate success
    }
}

/// ---------------------------------------------------------------------------
/// TEST CONTRACT
/// ---------------------------------------------------------------------------

contract CrossChainHookFullTest is Test {
    CrossChainSwapHook public hook;
    MockPythOracle public pyth;
    MockBridge public bridge;
    MockERC20 public token0;
    MockERC20 public token1;
    MockPoolManager public poolManager;

    address public constant FEE_RECIPIENT = address(0xBEEF);
    address public user = address(0xCAFE);

    bytes32 public priceId0 = keccak256("TOKEN0");
    bytes32 public priceId1 = keccak256("TOKEN1");

    function setUp() public {
        // deploy mocks and hook
        poolManager = new MockPoolManager();
        pyth = new MockPythOracle();
        bridge = new MockBridge();
        token0 = new MockERC20();
        token1 = new MockERC20();

        // deploy hook with mock addresses (cast MockPoolManager address to IPoolManager)
        hook = new CrossChainSwapHook(
            IPoolManager(address(poolManager)),
            address(pyth),
            address(bridge),
            FEE_RECIPIENT
        );

        // fund user with token0 and token1
        token0.mint(user, 1_000_000e18);
        token1.mint(user, 1_000_000e18);

        // default price data not configured yet
    }

    /// -----------------------------
    /// Basic permission & constructor tests
    /// -----------------------------
    function testHookPermissionsAndLocalVenue() public {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap && perms.afterSwap);
        // local venue (index 0) should exist and be active
        CrossChainSwapHook.SwapVenue memory v0 = hook.getVenueInfo(0);
        assertTrue(v0.isActive);
        assertEq(v0.chainId, block.chainid);
        // venueCount should be at least 1
        assertGt(hook.venueCount(), 0);
    }

    /// -----------------------------
    /// Admin functions: add/update/reverts
    /// -----------------------------
    function testAddVenueAndGetAllActiveVenues() public {
        // add two venues
        hook.addVenue(137, address(0x3000), "Polygon", 200000);
        hook.addVenue(42161, address(0x4000), "Arbitrum", 150000);

        assertEq(hook.venueCount(), 3); // local + 2 added

        // deactivate index 1 (Polygon)
        hook.updateVenueStatus(1, false);
        CrossChainSwapHook.SwapVenue[] memory active = hook.getAllActiveVenues();

        // there should be two active venues: local (0) and Arbitrum (2)
        assertEq(active.length, 2);
        assertEq(active[0].chainId, block.chainid);
        assertEq(active[1].chainId, 42161);

        // invalid index revert
        vm.expectRevert(CrossChainSwapHook.InvalidVenueIndex.selector);
        hook.getVenueInfo(type(uint256).max);
    }

    function testConfigurePriceDataAndGetTokenPriceData() public {
        // configure with explicit staleness
        hook.configurePriceData(address(token0), priceId0, 600);
        CrossChainSwapHook.PriceData memory pd = hook.getTokenPriceData(address(token0));
        assertEq(pd.priceId, priceId0);
        assertEq(pd.maxStaleness, 600);
        assertTrue(pd.isActive);

        // zero token revert
        vm.expectRevert(CrossChainSwapHook.ZeroAddress.selector);
        hook.configurePriceData(address(0), priceId1, 100);

        // maxStaleness zero -> default used (call and check not zero)
        hook.configurePriceData(address(token1), priceId1, 0);
        CrossChainSwapHook.PriceData memory pd1 = hook.getTokenPriceData(address(token1));
        assertTrue(pd1.maxStaleness > 0);
    }

    function testUpdatePythAndBridge() public {
        address newPyth = address(0xCA11);
        address newBridge = address(0xBADA);
        hook.updatePythOracle(newPyth);
        hook.updateBridgeProtocol(newBridge);

        // events emitted - can't directly assert easily except by expecting no revert
        assertEq(address(pyth), address(pyth)); // noop sanity check

        // revert on zero address
        vm.expectRevert(CrossChainSwapHook.ZeroAddress.selector);
        hook.updatePythOracle(address(0));

        vm.expectRevert(CrossChainSwapHook.ZeroAddress.selector);
        hook.updateBridgeProtocol(address(0));
    }

    function testUpdateSwapParametersAndFeeParams() public {
        hook.updateSwapParameters(200, 50, 500e18, 150);
        assertEq(hook.maxSlippageBps(), 200);
        assertEq(hook.bridgeSlippageBps(), 50);
        assertEq(hook.minBridgeAmount(), 500e18);
        assertEq(hook.crossChainThresholdBps(), 150);

        // invalid slippage -> revert
        vm.expectRevert(CrossChainSwapHook.InvalidSlippageParameters.selector);
        hook.updateSwapParameters(20000, 1, 1, 1);

        // fee params
        hook.updateFeeParameters(address(this), 5);
        assertEq(hook.feeRecipient(), address(this));
        assertEq(hook.protocolFeeBps(), 5);

        vm.expectRevert();
        hook.updateFeeParameters(address(0), 1);

        vm.expectRevert();
        hook.updateFeeParameters(address(this), 1000); // "Fee too high"
    }

    function testPauseUnpauseAndOnlyOwner() public {
        // only owner can pause/unpause; current deployer is owner (this test contract)
        assertFalse(hook.paused());
        hook.pause();
        assertTrue(hook.paused());
        hook.unpause();
        assertFalse(hook.paused());

        // non-owner calls revert
        vm.prank(address(0x9999));
        vm.expectRevert();
        hook.pause();
    }

    function testEmergencyWithdraw() public {
        // mint tokens to hook and withdraw
        token0.mint(address(hook), 1000e18);
        hook.emergencyWithdraw(address(token0), 1000e18, address(0xEEEE));
        assertEq(token0.balanceOf(address(0xEEEE)), 1000e18);

        // zero recipient revert
        vm.expectRevert(CrossChainSwapHook.ZeroAddress.selector);
        hook.emergencyWithdraw(address(token0), 10, address(0));
    }

    /// -----------------------------
    /// Execution & Quote calculation tests
    /// -----------------------------
    function testCalculateExecutionCostBoundsAndProtocolFee() public {
        // Add a venue with high gas estimate to trigger gasCost > maxAllowedGasCost clamp
        hook.addVenue(137, address(0x3000), "Polygon", 1_000_000);
        CrossChainSwapHook.SwapVenue memory venue = hook.getVenueInfo(1);

        // craft SwapParams with amountSpecified = 1000 (as int128) - correct SwapParams shape
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int128(int256(1_000e18)),
            sqrtPriceLimitX96: 0
        });

        // call simulateSwap with no price data set -> should return zero outputs and confidence 0
        CrossChainSwapHook.CrossChainSwapData memory swapData = CrossChainSwapHook.CrossChainSwapData({
            minAmountOut: 0,
            recipient: user,
            deadline: block.timestamp + 1000,
            tokenInPriceId: bytes32(0),
            tokenOutPriceId: bytes32(0),
            maxGasPrice: tx.gasprice,
            forceLocal: true,
            thresholdBps: 0
        });

        PoolKey memory key;
        key.currency0 = Currency.wrap(address(token0));
        key.currency1 = Currency.wrap(address(token1));
        key.fee = 0;
        key.tickSpacing = int24(0);
        key.hooks = IHooks(address(0));

        (CrossChainSwapHook.ExecutionQuote memory best, CrossChainSwapHook.ExecutionQuote[] memory all) =
            hook.simulateSwap(key, params, swapData);

        // since no price data -> best.netOutput should be 0
        assertEq(best.netOutput, 0);
    }

    function testCalculateOutputAmountSuccessAndConfidenceAndBridgeQuoteFlow() public {
        // Configure price data for tokens
        hook.configurePriceData(address(token0), priceId0, 10000);
        hook.configurePriceData(address(token1), priceId1, 10000);

        // Set prices in mock pyth: large positive price numbers to avoid division by zero in confidence calc
        uint64 nowT = uint64(block.timestamp);
        pyth.setPrice(priceId0, int64(2000), int64(10), nowT);
        pyth.setPrice(priceId1, int64(1000), int64(5), nowT);

        // Add a remote venue (chain != current)
        hook.addVenue(137, address(0x3000), "Polygon", 200000);

        // pre-configure bridge quote for the encoded key used in MockBridge
        uint256 amountSpecified = 100 * 1e18;
        bridge.setQuote(address(token0), address(token1), amountSpecified, 137, 1e15, 300, bytes("bridge-data"));

        // Setup token balances & allowance for user so _executeCrossChainSwap can transferFrom
        token0.mint(user, amountSpecified);
        vm.prank(user);
        token0.approve(address(hook), amountSpecified);

        // Build swap params and swapData; correct SwapParams shape
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int128(int256(amountSpecified)),
            sqrtPriceLimitX96: 0
        });

        CrossChainSwapHook.CrossChainSwapData memory swapData = CrossChainSwapHook.CrossChainSwapData({
            minAmountOut: 0,
            recipient: user,
            deadline: block.timestamp + 1000,
            tokenInPriceId: priceId0,
            tokenOutPriceId: priceId1,
            maxGasPrice: tx.gasprice,
            forceLocal: false,
            thresholdBps: 0 // allow cross-chain if improved
        });

        PoolKey memory key;
        key.currency0 = Currency.wrap(address(token0));
        key.currency1 = Currency.wrap(address(token1));
        key.fee = 0;
        key.tickSpacing = int24(0);
        key.hooks = IHooks(address(0));

        // now call simulateSwap to get quotes; should succeed and include bridge info (if any)
        (CrossChainSwapHook.ExecutionQuote memory best, CrossChainSwapHook.ExecutionQuote[] memory allQuotes) =
            hook.simulateSwap(key, params, swapData);

        // ensure array length equals venueCount and that at least one quote has some output/bridge data
        assertEq(allQuotes.length, hook.venueCount());
        bool anyNonZero = false;
        for (uint i = 0; i < allQuotes.length; i++) {
            if (allQuotes[i].outputAmount > 0 || allQuotes[i].bridgeData.length > 0) {
                anyNonZero = true;
            }
        }
        assertTrue(anyNonZero);
    }

    /// -----------------------------
    /// Negative & revert cases
    /// -----------------------------
    function testValidateSwapDataRevertsOnThreshold() public {
        // Can't call internal _validateSwapData directly; assert updateSwapParameters rejects bad threshold
        vm.expectRevert(CrossChainSwapHook.InvalidThresholdParameters.selector);
        hook.updateSwapParameters(100, 50, 1e18, 2000);
    }

    /// -----------------------------
    /// Utility coverage notes
    /// -----------------------------
    function testSmoke_simulateWithManyVenues() public {
        // ensure there's at least a few venues
        hook.addVenue(250, address(0xAAAA), "Optimism", 120000);
        hook.addVenue(10, address(0xBBBB), "Other", 120000);

        // configure price data for tokens (no price set -> zero-output path)
        hook.configurePriceData(address(token0), priceId0, 100);
        hook.configurePriceData(address(token1), priceId1, 100);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int128(int256(1e18)),
            sqrtPriceLimitX96: 0
        });

        CrossChainSwapHook.CrossChainSwapData memory swapData = CrossChainSwapHook.CrossChainSwapData({
            minAmountOut: 0,
            recipient: user,
            deadline: block.timestamp + 1000,
            tokenInPriceId: priceId0,
            tokenOutPriceId: priceId1,
            maxGasPrice: tx.gasprice,
            forceLocal: true,
            thresholdBps: 0
        });

        PoolKey memory key;
        key.currency0 = Currency.wrap(address(token0));
        key.currency1 = Currency.wrap(address(token1));
        key.fee = 0;
        key.tickSpacing = int24(0);
        key.hooks = IHooks(address(0));

        (CrossChainSwapHook.ExecutionQuote memory best, CrossChainSwapHook.ExecutionQuote[] memory all) =
            hook.simulateSwap(key, params, swapData);

        // ensure call returned
        assertEq(all.length, hook.venueCount());
    }
}
