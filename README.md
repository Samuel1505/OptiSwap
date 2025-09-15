# Cross-Chain Swap Optimization Hook for Uniswap V4

This is a Uniswap V4 hook implementation that optimizes swaps across multiple blockchains, automatically routing users to the most profitable execution venue.

## Project Structure

```
src/
├── CrossChainSwapHook.sol          # Main contract
├── interfaces/
│   ├── IPythOracle.sol            # Pyth oracle interface
│   └── IBridgeProtocol.sol        # Bridge protocol interface
└── libraries/
    ├── PriceCalculator.sol        # Price calculation utilities
    └── VenueComparator.sol        # Venue comparison logic
```

## Contracts Overview

### CrossChainSwapHook.sol

The main Uniswap V4 hook contract that handles cross-chain swap optimization. It inherits from Uniswap V4's `BaseHook` and OpenZeppelin's `Ownable`, `ReentrancyGuard`, and `Pausable`.

**Hook Implementation:**
- Implements `beforeSwap` and `afterSwap` hooks from Uniswap V4
- Automatically analyzes cross-chain opportunities before each swap
- Routes users to the most profitable execution venue

**Key State Variables:**
- `pythOracle`: IPythOracle instance for price feeds
- `bridgeProtocol`: IBridgeProtocol instance for cross-chain operations
- `venues[]`: Array of configured execution venues
- `tokenPriceData[]`: Mapping of tokens to their price feed configurations
- `maxSlippageBps`: Maximum allowed slippage (default: 300 = 3%)
- `protocolFeeBps`: Protocol fee in basis points (default: 10 = 0.1%)
- `crossChainThresholdBps`: Minimum improvement threshold for cross-chain (default: 200 = 2%)

**Hook Functions:**
- `_beforeSwap()`: Analyzes cross-chain opportunities and executes if profitable
- `_afterSwap()`: Handles post-swap logic and emits events
- `getHookPermissions()`: Returns hook permissions for V4 validation

**Admin Functions:**
- `addVenue()`: Adds new execution venue
- `configurePriceData()`: Configures token price feeds
- `simulateSwap()`: Returns quotes without executing

**Structs:**
```solidity
struct CrossChainSwapData {
    uint256 minAmountOut;
    address recipient;
    uint256 deadline;
    bytes32 tokenInPriceId;
    bytes32 tokenOutPriceId;
    uint256 maxGasPrice;
    bool forceLocal;
    uint256 thresholdBps; // Minimum improvement threshold in basis points
}

struct SwapVenue {
    uint256 chainId;
    address venueAddress;
    string name;
    bool isActive;
    uint256 baseGasEstimate;
    uint256 lastUpdateTime;
    uint8 reliabilityScore;
}

struct ExecutionQuote {
    uint256 outputAmount;
    uint256 totalCost;
    uint256 netOutput;
    uint256 venueIndex;
    uint256 executionTime;
    bool requiresBridge;
    bytes bridgeData;
    uint8 confidenceScore;
}
```

### IPythOracle.sol

Interface for Pyth Network price oracles.

**Key Functions:**
- `getPrice(bytes32 id)`: Returns current price for a price ID
- `updatePriceFeeds(bytes[] calldata updateData)`: Updates price feeds
- `getUpdateFee(bytes[] calldata updateData)`: Gets required fee for updates

**Structs:**
```solidity
struct Price {
    int64 price;
    uint64 conf;
    int32 expo;
    uint publishTime;
}
```

### IBridgeProtocol.sol

Interface for cross-chain bridge protocols.

**Key Functions:**
- `getQuote(address tokenIn, address tokenOut, uint256 amountIn, uint256 destinationChainId)`: Gets bridge quote
- `bridge(address tokenIn, uint256 amountIn, uint256 destinationChainId, address recipient, bytes calldata bridgeData)`: Executes bridge

**Structs:**
```solidity
struct BridgeQuote {
    uint256 outputAmount;
    uint256 bridgeFee;
    uint256 estimatedTime;
    bytes bridgeData;
    uint256 destinationChainId;
    uint256 minAmount;
    uint256 maxAmount;
    uint256 validUntil;
}
```

### PriceCalculator.sol

Library for price calculations using Pyth oracle data.

**Key Functions:**
- `calculateOutputAmount(Price memory priceIn, Price memory priceOut, uint256 amountIn)`: Calculates output amount
- `calculateOutputAmountWithConfidence(...)`: Calculates with confidence scoring
- `applySlippage(uint256 outputAmount, uint256 slippageBps)`: Applies slippage protection
- `calculatePriceImpact(uint256 basePrice, uint256 tradeSize, uint256 liquidityDepth)`: Calculates price impact

**Constants:**
- `MAX_PRICE_STALENESS = 600`: Maximum price staleness (10 minutes)
- `MIN_CONFIDENCE_SCORE = 20`: Minimum confidence score
- `PRICE_PRECISION = 1e18`: Price precision for calculations

### VenueComparator.sol

Library for comparing and ranking execution venues.

**Key Functions:**
- `calculateVenueScore(ComparisonData memory data, ScoringWeights memory weights, ComparisonData memory referenceData)`: Calculates venue score
- `compareVenues(ComparisonData memory venue1, ComparisonData memory venue2, ScoringWeights memory weights, ComparisonData memory referenceData)`: Compares two venues
- `rankVenues(ComparisonData[] memory venues, ScoringWeights memory weights, ComparisonData memory referenceData)`: Ranks all venues

**Scoring Weights:**
```solidity
struct ScoringWeights {
    uint8 outputWeight;        // 35% - Net output amount
    uint8 costWeight;          // 20% - Execution costs
    uint8 timeWeight;          // 15% - Execution speed
    uint8 reliabilityWeight;   // 10% - Venue reliability
    uint8 confidenceWeight;    // 10% - Price confidence
    uint8 liquidityWeight;     // 5% - Available liquidity
    uint8 performanceWeight;   // 5% - Historical performance
}
```

## Usage Example

```solidity
// Deploy the hook contract
CrossChainSwapHook hook = new CrossChainSwapHook(
    poolManagerAddress,
    pythOracleAddress,
    bridgeProtocolAddress,
    feeRecipientAddress
);

// Add execution venues
hook.addVenue(137, polygonVenueAddress, "Polygon Uniswap", 200000);
hook.addVenue(42161, arbitrumVenueAddress, "Arbitrum Uniswap", 150000);

// Configure price feeds
hook.configurePriceData(WETH, ETH_PRICE_ID, 600);
hook.configurePriceData(USDC, USDC_PRICE_ID, 300);

// Create a Uniswap V4 pool with the hook
PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(WETH),
    currency1: Currency.wrap(USDC),
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

poolManager.initialize(poolKey, sqrtPriceX96);

// Users can now swap through the pool, and the hook will automatically
// analyze cross-chain opportunities and route to the best venue
```

## Events

The contract emits several events for monitoring:

- `CrossChainSwapExecuted`: When a cross-chain swap is executed
- `LocalSwapOptimized`: When local execution is chosen
- `VenueConfigured`: When venues are added or updated
- `PriceOracleUpdated`: When oracle is changed
- `BridgeProtocolUpdated`: When bridge protocol is changed
- `SwapParametersUpdated`: When parameters are updated
- `EmergencyWithdraw`: When emergency withdrawal occurs

## Admin Functions

Owner-only functions for configuration:

- `addVenue()`: Add new execution venue
- `updateVenueStatus()`: Enable/disable venues
- `configurePriceData()`: Configure token price feeds
- `updatePythOracle()`: Change oracle address
- `updateBridgeProtocol()`: Change bridge protocol
- `updateSwapParameters()`: Update slippage and limits
- `updateFeeParameters()`: Update fee settings
- `pause()`/`unpause()`: Emergency pause functionality
- `emergencyWithdraw()`: Recover stuck tokens

## Security Features

- **ReentrancyGuard**: Prevents reentrancy attacks
- **Pausable**: Emergency pause functionality
- **Ownable2Step**: Two-step ownership transfer
- **Slippage Protection**: Configurable slippage limits
- **Price Validation**: Staleness and confidence checks
- **Bridge Validation**: Quote validation before execution

## Development

### Setup
```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Run tests with verbose output
forge test -vvv
```

### Testing
The project includes basic tests in `test/Counter.t.sol`. Additional tests should be added for the main contract functionality.

### Deployment
```bash
# Set environment variables
export PRIVATE_KEY="your_private_key"
export POOL_MANAGER="0x..."
export PYTH_ORACLE="0x..."
export BRIDGE_PROTOCOL="0x..."
export FEE_RECIPIENT="0x..."

# Deploy the hook
forge script script/DeployCrossChainHook.s.sol --rpc-url <RPC_URL> --broadcast

# Verify on block explorer
forge verify-contract <CONTRACT_ADDRESS> src/CrossChainSwapHook.sol:CrossChainSwapHook --chain-id <CHAIN_ID>
```

## Dependencies

- Uniswap V4 Core (`v4-core`)
- Uniswap V4 Periphery (`v4-periphery`)
- OpenZeppelin Contracts v5.4.0
- Foundry (forge, cast, anvil)
- Solidity ^0.8.24

## License

MIT