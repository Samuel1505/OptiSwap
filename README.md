# Cross-Chain Swap Optimization Hook 

## 📋 Project Overview

This project implements a **Uniswap v4 Hook** that enables **cross-chain swap optimization**. Instead of executing swaps only on the local chain, the hook:

1. **Compares prices** across multiple blockchains (Ethereum, Polygon, Arbitrum, etc.)
2. **Factors in costs** (gas fees, bridge fees, execution time)
3. **Routes the swap** to the chain with the best net execution price
4. **Executes via bridge** if a remote chain offers better rates

Think of it as a "smart router" that finds the best deal across the entire multi-chain ecosystem.

## 🏗️ Architecture Overview

```
User initiates swap
        ↓
Uniswap v4 Pool calls beforeSwap()
        ↓
Hook queries all venues (chains)
        ↓
Calculates best execution venue
        ↓
If remote chain is better:
├── Bridge tokens to target chain
└── Execute swap there
Else:
└── Allow local swap to proceed
```

##  Contract Structure

###  Core Contracts

#### `CrossChainSwapHook.sol` - Main Hook Contract
**Purpose**: it implements Uniswap v4 hook interface

**Key Functions**:
```solidity
// Main hook function called by Uniswap v4
function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)

// Finds the best execution venue across all chains
function getBestExecutionVenue(SwapRequest memory request) returns (ExecutionQuote memory bestQuote)

// Simulates swap across all venues without executing
function simulateSwap(SwapRequest memory request) returns (ExecutionQuote memory bestQuote, ExecutionQuote[] memory allQuotes)
```

**State Variables**:
- `venues[]` - Array of all configured execution venues (chains/DEXs)
- `tokenPriceData[]` - Mapping of tokens to their Pyth price feed IDs
- `maxSlippageBps` - Maximum allowed slippage (300 = 3%)
- `bridgeSlippageBps` - Additional slippage for bridge operations

#### `PriceCalculator.sol` - Price Calculation Library
**Purpose**: Handles all price conversions and calculations using Pyth oracles

**Key Functions**:

// Converts oracle prices to output amounts
function calculateOutputAmount(Price memory priceIn, Price memory priceOut, uint256 amountIn) returns (uint256 outputAmount)

// Calculates with confidence scoring
function calculateOutputAmountWithConfidence(...) returns (uint256 outputAmount, uint8 confidenceScore)

// Applies slippage protection
function applySlippage(uint256 outputAmount, uint256 slippageBps) returns (uint256 adjustedAmount)
```

#### `VenueComparator.sol` - Venue Ranking Library
**Purpose**: Sophisticated algorithms to rank and compare execution venues

**Key Functions**:
```solidity
// Calculates comprehensive venue score (0-100)
function calculateVenueScore(ComparisonData memory data, ScoringWeights memory weights) returns (uint256 score)

// Compares two venues head-to-head
function compareVenues(ComparisonData memory venue1, ComparisonData memory venue2) returns (bool isBetter)

// Ranks all venues by score
function rankVenues(ComparisonData[] memory venues) returns (uint256[] memory rankedIndices)
```

###  Interface Contracts

#### `IPythOracle.sol` - Pyth Network Interface
**Purpose**: Standardized interface for Pyth price oracles

**Key Structures**:
```solidity
struct Price {
    int64 price;        // Price value
    uint64 conf;        // Confidence interval
    int32 expo;         // Decimal exponent
    uint publishTime;   // Timestamp
}
```

#### `IBridgeProtocol.sol` - Bridge Integration Interface
**Purpose**: Standardized interface for cross-chain bridge protocols

**Key Structures**:
```solidity
struct BridgeQuote {
    uint256 outputAmount;      // Expected tokens on destination
    uint256 bridgeFee;         // Cost to bridge
    uint256 estimatedTime;     // Time to complete (seconds)
    bytes bridgeData;          // Protocol-specific data
}
```

##  Execution Flow Deep Dive

### 1. Swap Initiation
```solidity
// User calls Uniswap v4 swap with hook data
SwapRequest memory request = SwapRequest({
    tokenIn: WETH,
    tokenOut: USDC, 
    amountIn: 1e18,                    // 1 ETH
    minAmountOut: 1900e6,             // At least 1900 USDC
    recipient: msg.sender,
    deadline: block.timestamp + 3600,
    tokenInPriceId: ETH_USD_PRICE_ID,
    tokenOutPriceId: USDC_USD_PRICE_ID,
    maxGasPrice: 50 gwei,
    forceLocal: false
});

bytes memory hookData = abi.encode(request);
poolManager.swap(poolKey, swapParams, hookData);
```

### 2. Venue Analysis
The hook analyzes each configured venue:

```solidity
// For each venue (chain), calculate:
struct ExecutionQuote {
    uint256 outputAmount;     // How much USDC we'd get
    uint256 totalCost;        // Gas + bridge fees
    uint256 netOutput;        // outputAmount - totalCost
    uint256 venueIndex;       // Which venue this is
    bool requiresBridge;      // Whether bridging is needed
    uint8 confidenceScore;    // Price data confidence (0-100)
}
```

### 3. Best Venue Selection
```solidity
// Example scenario:
// Local (Ethereum):     1950 USDC output - 50 USDC gas = 1900 USDC net
// Polygon:              1970 USDC output - 30 USDC bridge fee = 1940 USDC net  BEST
// Arbitrum:             1960 USDC output - 20 USDC bridge fee = 1940 USDC net
// Optimism:             1955 USDC output - 25 USDC bridge fee = 1930 USDC net

// Hook selects Polygon venue
```

### 4. Execution Decision
```solidity
if (bestQuote.venueIndex == 0) {
    // Local is best - allow normal Uniswap swap
    return (ZERO_DELTA, 0);
} else {
    // Remote chain is best - execute bridge
    _executeCrossChainSwap(sender, request, bestQuote, swapId);
    // Prevent local swap by consuming input tokens
    return (toBeforeSwapDelta(-amountSpecified, 0), 0);
}
```


hook.addVenue(137, polygonVenueAddress, "Polygon Uniswap V3", 200000);
hook.addVenue(42161, arbitrumVenueAddress, "Arbitrum Uniswap V3", 150000);

// 2. Configure price feeds
hook.configurePriceData(WETH, ETH_USD_PRICE_ID, 600);
hook.configurePriceData(USDC, USDC_USD_PRICE_ID, 300);

// 3. Set up bridge quotes (via bridge protocol)
bridgeProtocol.setQuote(WETH, POLYGON_CHAIN_ID, betterRate, bridgeFee, estimatedTime);
```

## 🔧 Key Configuration Parameters

### Slippage Settings
```solidity
maxSlippageBps = 300;      // 3% max slippage for any swap
bridgeSlippageBps = 100;   // 1% additional slippage for bridges
minBridgeAmount = 100e18;  // Only bridge amounts > 100 tokens
```

### Fee Configuration
```solidity
protocolFeeBps = 10;       // 0.1% protocol fee
maxGasCostBps = 500;       // Max 5% of swap value in gas costs
```

### Venue Scoring Weights
```solidity
struct ScoringWeights {
    uint8 outputWeight = 35;        // 35% - Net output amount
    uint8 costWeight = 20;          // 20% - Execution costs  
    uint8 timeWeight = 15;          // 15% - Execution speed
    uint8 reliabilityWeight = 10;   // 10% - Venue reliability
    uint8 confidenceWeight = 10;    // 10% - Price confidence
    uint8 liquidityWeight = 5;      // 5% - Available liquidity
    uint8 performanceWeight = 5;    // 5% - Historical performance
}
```

## 🚨 Critical Integration Points

### 1. **Pyth Oracle Integration**
```solidity
// Price IDs must match Pyth Network exactly
bytes32 constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

// Price staleness must be configured appropriately
uint256 maxStaleness = 600; // 10 minutes for volatile assets
```

### 2. **Bridge Protocol Integration** 
```solidity
// Bridge must implement IBridgeProtocol interface
// Quote validation is critical for security
BridgeQuote memory quote = bridgeProtocol.getQuote(tokenIn, tokenOut, amountIn, chainId);
require(quote.outputAmount >= minAmountOut, "Insufficient bridge output");
```

### 3. **Uniswap v4 Hook Registration**
```solidity
// Hook address must be deterministic and match expected permissions
address hookAddress = CREATE2_DEPLOY_WITH_CORRECT_SALT;
IHooks hooks = IHooks(hookAddress);

// Hook permissions must match implementation
Hooks.Permissions memory permissions = hooks.getHookPermissions();
require(permissions.beforeSwap == true, "Missing beforeSwap permission");
```

## 🛡️ Security Considerations

### **Price Manipulation Resistance**
- Multiple price feed validation
- Confidence interval checking  
- Time-weighted average price (TWAP) support
- Staleness protection

### **Bridge Security**
- Quote validation before execution
- Slippage protection on bridge operations
- Timeout enforcement
- Failed bridge refund mechanisms

### **Access Controls**
```solidity
// Owner-only functions
onlyOwner: addVenue, updateParameters, pause, emergencyWithdraw

// Emergency functions
pause(): Stops all hook operations
emergencyWithdraw(): Recovers stuck tokens
```

## 🔍 Debugging Guide

### Common Issues

1. **"Invalid price data" errors**
   - Check Pyth price ID configuration
   - Verify price feed staleness settings
   - Ensure oracle has recent price updates

2. **"Insufficient output amount" errors**
   - Bridge rates may have changed
   - Check slippage settings
   - Verify minAmountOut is reasonable

3. **Gas estimation failures**
   - Update venue gas estimates
   - Check maxGasCostBps settings
   - Verify sufficient ETH for gas

### Debug Commands
```bash
# Run with maximum verbosity
forge test -vvvv

# Enable transaction traces
forge test --trace

# Check specific function calls
forge test --match-test testFunctionName -vvv
```

## 📊 Monitoring & Analytics

### Key Events to Monitor
```solidity
// Successful cross-chain execution
event CrossChainSwapExecuted(
    address indexed user,
    address indexed tokenIn, 
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint256 destinationChainId,
    address venue,
    uint256 bridgeFee,
    bytes32 indexed swapId
);

// Local optimization
event LocalSwapOptimized(...);

// Configuration changes  
event VenueConfigured(...);
event SwapParametersUpdated(...);
```

### Performance Metrics
- Cross-chain execution rate vs local
- Average savings per swap
- Venue performance rankings
- Bridge success rates
- Gas cost analysis

## 🤝 Collaboration Workflow

### **For Frontend Developers**
```javascript
// Example integration
const swapRequest = {
    tokenIn: WETH_ADDRESS,
    tokenOut: USDC_ADDRESS, 
    amountIn: ethers.parseEther("1"),
    minAmountOut: ethers.parseUnits("1900", 6),
    recipient: userAddress,
    deadline: Math.floor(Date.now() / 1000) + 3600,
    tokenInPriceId: ETH_USD_PRICE_ID,
    tokenOutPriceId: USDC_USD_PRICE_ID,
    maxGasPrice: ethers.parseUnits("50", "gwei"),
    forceLocal: false
};

// Get quote before executing
const [bestQuote, allQuotes] = await hook.simulateSwap(swapRequest);

// Execute via Uniswap v4
const hookData = ethers.AbiCoder.defaultAbiCoder().encode([SwapRequestType], [swapRequest]);
await poolManager.swap(poolKey, swapParams, hookData);
```

### **For Bridge Protocol Developers**
```solidity
// Implement IBridgeProtocol interface
contract YourBridge is IBridgeProtocol {
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn, uint256 destinationChainId) 
        external view returns (BridgeQuote memory) {
        // Return accurate quote with fees and timing
    }
    
    function bridge(address tokenIn, uint256 amountIn, uint256 destinationChainId, address recipient, bytes calldata bridgeData) 
        external payable returns (bytes32 transactionId) {
        // Execute the bridge operation
    }
}
```

### **For Oracle Developers**
```solidity
// Ensure Pyth price feed compatibility
// Price IDs must be consistent across chains
// Update frequency should match volatility
// Confidence intervals should be properly calculated
```

This system is designed to be **modular and extensible**. Each component can be upgraded independently, and new venue types, bridge protocols, or pricing oracles can be added without changing the core logic.

The hook demonstrates advanced Uniswap v4 capabilities while solving a real problem: **fragmented liquidity across chains**. Users get better execution, and the DeFi ecosystem becomes more efficient and unified.