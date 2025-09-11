# Cross-Chain Swap Optimization Hook

This is the  implementation of a cross-chain swap optimization system that finds the best execution venue across multiple blockchains.

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

The main contract that handles cross-chain swap optimization. It inherits from OpenZeppelin's `Ownable`, `ReentrancyGuard`, and `Pausable`.

**Key State Variables:**
- `pythOracle`: IPythOracle instance for price feeds
- `bridgeProtocol`: IBridgeProtocol instance for cross-chain operations
- `venues[]`: Array of configured execution venues
- `tokenPriceData[]`: Mapping of tokens to their price feed configurations
- `maxSlippageBps`: Maximum allowed slippage (default: 300 = 3%)
- `protocolFeeBps`: Protocol fee in basis points (default: 10 = 0.1%)

**Main Functions:**
- `executeSwap(SwapRequest memory request)`: Executes the swap optimization
- `simulateSwap(SwapRequest memory request)`: Returns quotes without executing
- `addVenue(uint256 chainId, address venueAddress, string memory name, uint256 gasEstimate)`: Adds new execution venue
- `configurePriceData(address token, bytes32 priceId, uint256 maxStaleness)`: Configures token price feeds

**Structs:**
```solidity
struct SwapRequest {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    address recipient;
    uint256 deadline;
    bytes32 tokenInPriceId;
    bytes32 tokenOutPriceId;
    uint256 maxGasPrice;
    bool forceLocal;
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
// Deploy the contract
CrossChainSwapHook hook = new CrossChainSwapHook(
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

// Execute swap
SwapRequest memory request = SwapRequest({
    tokenIn: WETH,
    tokenOut: USDC,
    amountIn: 1e18,
    minAmountOut: 1900e6,
    recipient: msg.sender,
    deadline: block.timestamp + 3600,
    tokenInPriceId: ETH_PRICE_ID,
    tokenOutPriceId: USDC_PRICE_ID,
    maxGasPrice: 50 gwei,
    forceLocal: false
});

bytes32 swapId = hook.executeSwap(request);
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
# Deploy to testnet
forge script script/Counter.s.sol --rpc-url <RPC_URL> --broadcast

# Verify on block explorer
forge verify-contract <CONTRACT_ADDRESS> src/CrossChainSwapHook.sol:CrossChainSwapHook --chain-id <CHAIN_ID>
```

## Dependencies

- OpenZeppelin Contracts v5.4.0
- Foundry (forge, cast, anvil)
- Solidity ^0.8.24

## License

MIT