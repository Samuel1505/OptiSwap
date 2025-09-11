# Cross-Chain Swap Optimization Hook

A Uniswap v4 hook that finds the best swap execution across multiple chains by comparing prices, gas costs, and bridge fees.

## Overview

This hook analyzes swap opportunities across different blockchains and routes to the venue offering the best net execution price. Instead of just swapping locally, it considers:

- Price differences across chains
- Gas costs and bridge fees  
- Execution time
- Liquidity availability

## How It Works

1. User initiates a swap on Uniswap v4
2. Hook queries all configured venues (chains/DEXs)
3. Calculates net output after costs for each venue
4. Routes to the venue with the best net result
5. If remote chain is better, bridges tokens and executes there

## Contract Structure

### CrossChainSwapHook.sol
Main hook contract that implements the Uniswap v4 interface.

Key functions:
- `executeSwap()` - Main swap execution function
- `simulateSwap()` - Get quotes without executing
- `addVenue()` - Add new execution venues

### PriceCalculator.sol
Library for price calculations using Pyth oracles.

- `calculateOutputAmount()` - Convert oracle prices to output amounts
- `applySlippage()` - Apply slippage protection
- `calculatePriceImpact()` - Calculate price impact

### VenueComparator.sol
Library for ranking and comparing execution venues.

- `calculateVenueScore()` - Score venues 0-100
- `compareVenues()` - Compare two venues
- `rankVenues()` - Rank all venues by score

### Interfaces

- `IPythOracle.sol` - Pyth Network price oracle interface
- `IBridgeProtocol.sol` - Cross-chain bridge interface

## Usage

### Basic Setup

```solidity
// Deploy the hook
CrossChainSwapHook hook = new CrossChainSwapHook(
    pythOracle,
    bridgeProtocol, 
    feeRecipient
);

// Add venues
hook.addVenue(137, polygonVenue, "Polygon", 200000);
hook.addVenue(42161, arbitrumVenue, "Arbitrum", 150000);

// Configure price feeds
hook.configurePriceData(WETH, ETH_PRICE_ID, 600);
hook.configurePriceData(USDC, USDC_PRICE_ID, 300);
```

### Executing Swaps

```solidity
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

## Configuration

### Slippage Settings
- `maxSlippageBps`: 300 (3% max slippage)
- `bridgeSlippageBps`: 100 (1% additional for bridges)
- `minBridgeAmount`: 100e18 (minimum amount to bridge)

### Fee Configuration
- `protocolFeeBps`: 10 (0.1% protocol fee)
- `maxGasCostBps`: 500 (max 5% of swap value in gas)

### Venue Scoring
Venues are scored based on:
- 35% - Net output amount
- 20% - Execution costs
- 15% - Execution speed
- 10% - Venue reliability
- 10% - Price confidence
- 5% - Available liquidity
- 5% - Historical performance

## Security

### Price Protection
- Multiple price feed validation
- Confidence interval checking
- Staleness protection
- TWAP support

### Bridge Security
- Quote validation before execution
- Slippage protection
- Timeout enforcement
- Refund mechanisms for failed bridges

### Access Control
- Owner-only configuration functions
- Emergency pause functionality
- Emergency withdraw for stuck tokens

## Events

```solidity
event CrossChainSwapExecuted(
    address indexed user,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint256 destinationChainId,
    address venue,
    uint256 bridgeFee,
    bytes32 swapId
);

event LocalSwapOptimized(
    address indexed user,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 expectedOut,
    bytes32 swapId
);
```

## Development

### Testing
```bash
forge test
forge test -vvv  # verbose output
```

### Building
```bash
forge build
```

### Deployment
```bash
forge script script/Counter.s.sol --rpc-url <RPC_URL> --broadcast
```

## Integration

### Frontend Integration
```javascript
// Get quote
const [bestQuote, allQuotes] = await hook.simulateSwap(swapRequest);

// Execute swap
const hookData = ethers.AbiCoder.defaultAbiCoder().encode(
    ["tuple(address,address,uint256,uint256,address,uint256,bytes32,bytes32,uint256,bool)"], 
    [swapRequest]
);
await poolManager.swap(poolKey, swapParams, hookData);
```

### Bridge Protocol Integration
Implement the `IBridgeProtocol` interface:

```solidity
contract YourBridge is IBridgeProtocol {
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn, uint256 destinationChainId) 
        external view returns (BridgeQuote memory) {
        // Return accurate quote
    }
    
    function bridge(address tokenIn, uint256 amountIn, uint256 destinationChainId, address recipient, bytes calldata bridgeData) 
        external payable returns (bytes32 transactionId) {
        // Execute bridge
    }
}
```

## License

MIT