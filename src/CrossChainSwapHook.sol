// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IPythOracle.sol";
import "./interfaces/IBridgeProtocol.sol";
import "./libraries/PriceCalculator.sol";
import "./libraries/VenueComparator.sol";


contract CrossChainSwapHook is BaseHook, Ownable, ReentrancyGuard, Pausable {
    using PriceCalculator for IPythOracle.Price;
    using VenueComparator for VenueComparator.ComparisonData;

    // Events
    event CrossChainSwapExecuted(
        address indexed user,
        Currency indexed tokenIn,
        Currency indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 destinationChainId,
        address venue,
        uint256 bridgeFee,
        bytes32 swapId
    );

    event LocalSwapOptimized(
        address indexed user,
        Currency indexed tokenIn,
        Currency indexed tokenOut,
        uint256 amountIn,
        uint256 expectedOut,
        bytes32 swapId
    );

    event VenueConfigured(
        uint256 indexed chainId,
        address indexed venue,
        string name,
        uint256 gasEstimate,
        bool isActive
    );

    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event BridgeProtocolUpdated(address indexed oldBridge, address indexed newBridge);
    event SwapParametersUpdated(uint256 maxSlippageBps, uint256 bridgeSlippageBps, uint256 minBridgeAmount);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed recipient);

    // Errors
    error InvalidVenueIndex();
    error VenueNotActive();
    error InsufficientOutputAmount();
    error SwapExpired();
    error InvalidSlippageParameters();
    error InvalidThresholdParameters();
    error ZeroAddress();
    error TokenNotSupported();
    error BridgeAmountTooSmall();
    error ExcessiveGasCost();
    error PriceDataStale();
    error UnauthorizedCaller();
    error CrossChainNotProfitable();

    // Structs
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

    struct PriceData {
        bytes32 priceId;
        uint256 lastUpdateTime;
        uint256 maxStaleness;
        bool isActive;
    }

    // State variables
    IPythOracle public pythOracle;
    IBridgeProtocol public bridgeProtocol;
    uint256 public immutable CURRENT_CHAIN_ID;
    
    mapping(uint256 => SwapVenue) public venues;
    mapping(address => PriceData) public tokenPriceData;
    mapping(uint256 => bool) public supportedChains;
    
    uint256 public venueCount;
    uint256 public maxSlippageBps = 300; // 3%
    uint256 public bridgeSlippageBps = 100; // 1%
    uint256 public minBridgeAmount = 100e18;
    uint256 public maxGasCostBps = 500; // 5%
    uint256 public defaultPriceStaleness = 300; // 5 minutes
    address public feeRecipient;
    uint256 public protocolFeeBps = 10; // 0.1%
    uint256 public crossChainThresholdBps = 200; // 2% minimum improvement for cross-chain

    // Modifiers
    modifier validVenue(uint256 venueIndex) {
        if (venueIndex >= venueCount) revert InvalidVenueIndex();
        if (!venues[venueIndex].isActive) revert VenueNotActive();
        _;
    }

    modifier notExpired(uint256 deadline) {
        if (block.timestamp > deadline) revert SwapExpired();
        _;
    }

    // Constructor
    constructor(
        IPoolManager _poolManager,
        address _pythOracle,
        address _bridgeProtocol,
        address _feeRecipient
    ) BaseHook(_poolManager) Ownable(_feeRecipient) {
        if (_pythOracle == address(0)) revert ZeroAddress();
        if (_bridgeProtocol == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        pythOracle = IPythOracle(_pythOracle);
        bridgeProtocol = IBridgeProtocol(_bridgeProtocol);
        feeRecipient = _feeRecipient;
        CURRENT_CHAIN_ID = block.chainid;

        _addVenue(
            CURRENT_CHAIN_ID,
            address(this),
            "Local Swap",
            150000,
            100
        );

        supportedChains[CURRENT_CHAIN_ID] = true;
    }

    /// @notice Returns hook permissions for Uniswap V4
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Hook called before a swap to analyze cross-chain opportunities
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Decode hook data to get cross-chain swap parameters
        CrossChainSwapData memory swapData = abi.decode(hookData, (CrossChainSwapData));
        
        // Validate swap data
        _validateSwapData(swapData);
        
        // Analyze cross-chain opportunities
        ExecutionQuote memory bestQuote = _getBestExecutionVenue(key, params, swapData);
        
        // If cross-chain is more profitable, execute cross-chain swap
        if (bestQuote.venueIndex != 0 && !swapData.forceLocal) {
            if (_isCrossChainProfitable(bestQuote, params, swapData)) {
                _executeCrossChainSwap(sender, key, params, bestQuote, swapData);
                // Return early to prevent local swap
                return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
            }
        }
        
        // Continue with local swap
        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /// @notice Hook called after a swap to handle any post-swap logic
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Emit event for local swap completion
        emit LocalSwapOptimized(
            sender,
            key.currency0,
            key.currency1,
            uint256(int256(params.amountSpecified)),
            uint256(int256(delta.amount0())),
            keccak256(abi.encodePacked(sender, block.timestamp, key.currency0, key.currency1))
        );
        
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Get the best execution venue for a swap
    function _getBestExecutionVenue(
        PoolKey calldata key,
        SwapParams calldata params,
        CrossChainSwapData memory swapData
    ) internal view returns (ExecutionQuote memory bestQuote) {
        bestQuote.netOutput = 0;
        bestQuote.confidenceScore = 0;
        
        ExecutionQuote[] memory quotes = new ExecutionQuote[](venueCount);
        
        for (uint256 i = 0; i < venueCount; i++) {
            if (!venues[i].isActive) continue;
            
            quotes[i] = _getVenueQuote(key, params, venues[i], i, swapData);
            
            if (_isBetterQuote(quotes[i], bestQuote)) {
                bestQuote = quotes[i];
            }
        }
        
        return bestQuote;
    }

    /// @notice Get quote for a specific venue
    function _getVenueQuote(
        PoolKey calldata key,
        SwapParams calldata params,
        SwapVenue memory venue,
        uint256 venueIndex,
        CrossChainSwapData memory swapData
    ) internal view returns (ExecutionQuote memory quote) {
        quote.venueIndex = venueIndex;
        quote.requiresBridge = venue.chainId != CURRENT_CHAIN_ID;
        quote.executionTime = venue.chainId == CURRENT_CHAIN_ID ? 15 : 300;
        
        (quote.outputAmount, quote.confidenceScore) = _calculateOutputAmount(key, params, swapData);
        
        if (quote.outputAmount == 0) {
            return quote;
        }
        
        quote.totalCost = _calculateExecutionCost(key, params, venue, quote.requiresBridge);
        
        quote.netOutput = quote.outputAmount > quote.totalCost 
            ? quote.outputAmount - quote.totalCost 
            : 0;
        
        if (quote.requiresBridge && quote.netOutput > 0) {
            try bridgeProtocol.getQuote(
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                uint256(int256(params.amountSpecified)),
                venue.chainId
            ) returns (IBridgeProtocol.BridgeQuote memory bridgeQuote) {
                quote.bridgeData = bridgeQuote.bridgeData;
                quote.totalCost += bridgeQuote.bridgeFee;
                quote.executionTime = bridgeQuote.estimatedTime;
                
                quote.netOutput = quote.outputAmount > quote.totalCost 
                    ? quote.outputAmount - quote.totalCost 
                    : 0;
            } catch {
                quote.netOutput = 0;
            }
        }
        
        return quote;
    }

    /// @notice Calculate output amount using Pyth oracle
    function _calculateOutputAmount(
        PoolKey calldata key,
        SwapParams calldata params,
        CrossChainSwapData memory swapData
    ) internal view returns (uint256 outputAmount, uint8 confidenceScore) {
        PriceData memory priceDataIn = tokenPriceData[Currency.unwrap(key.currency0)];
        PriceData memory priceDataOut = tokenPriceData[Currency.unwrap(key.currency1)];
        
        if (!priceDataIn.isActive || !priceDataOut.isActive) {
            return (0, 0);
        }
        
        try pythOracle.getPrice(priceDataIn.priceId) returns (IPythOracle.Price memory priceIn) {
            try pythOracle.getPrice(priceDataOut.priceId) returns (IPythOracle.Price memory priceOut) {
                
                if (block.timestamp - priceIn.publishTime > priceDataIn.maxStaleness ||
                    block.timestamp - priceOut.publishTime > priceDataOut.maxStaleness) {
                    return (0, 0);
                }
                
                outputAmount = priceIn.calculateOutputAmount(priceOut, uint256(int256(params.amountSpecified)));
                outputAmount = outputAmount * (10000 - maxSlippageBps) / 10000;
                confidenceScore = _calculateConfidenceScore(priceIn, priceOut);
                
            } catch {
                return (0, 0);
            }
        } catch {
            return (0, 0);
        }
        
        return (outputAmount, confidenceScore);
    }

    /// @notice Calculate execution cost for a venue
    function _calculateExecutionCost(
        PoolKey calldata key,
        SwapParams calldata params,
        SwapVenue memory venue,
        bool requiresBridge
    ) internal view returns (uint256 totalCost) {
        uint256 gasPrice = tx.gasprice;
        uint256 gasCost = venue.baseGasEstimate * gasPrice;
        
        uint256 maxAllowedGasCost = uint256(int256(params.amountSpecified)) * maxGasCostBps / 10000;
        if (gasCost > maxAllowedGasCost) {
            gasCost = maxAllowedGasCost;
        }
        
        totalCost = gasCost;
        totalCost += uint256(int256(params.amountSpecified)) * protocolFeeBps / 10000;
        
        return totalCost;
    }

    /// @notice Check if cross-chain swap is profitable
    function _isCrossChainProfitable(
        ExecutionQuote memory quote,
        SwapParams calldata params,
        CrossChainSwapData memory swapData
    ) internal pure returns (bool) {
        if (quote.netOutput == 0) return false;
        
        // Calculate local swap output (simplified - in reality would use pool price)
        uint256 localOutput = uint256(int256(params.amountSpecified)) * 95 / 100; // Assume 5% slippage
        
        // Check if cross-chain provides sufficient improvement
        uint256 improvement = quote.netOutput > localOutput ? quote.netOutput - localOutput : 0;
        uint256 improvementBps = localOutput > 0 ? improvement * 10000 / localOutput : 0;
        
        return improvementBps >= swapData.thresholdBps;
    }

    /// @notice Execute cross-chain swap
    function _executeCrossChainSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        ExecutionQuote memory quote,
        CrossChainSwapData memory swapData
    ) internal {
        if (quote.netOutput < swapData.minAmountOut) revert InsufficientOutputAmount();
        
        SwapVenue memory venue = venues[quote.venueIndex];
        
        // Transfer tokens from sender to this contract
        IERC20(Currency.unwrap(key.currency0)).transferFrom(sender, address(this), uint256(int256(params.amountSpecified)));
        
        uint256 protocolFee = uint256(int256(params.amountSpecified)) * protocolFeeBps / 10000;
        if (protocolFee > 0) {
            IERC20(Currency.unwrap(key.currency0)).transfer(feeRecipient, protocolFee);
        }
        
        uint256 bridgeAmount = uint256(int256(params.amountSpecified)) - protocolFee;
        IERC20(Currency.unwrap(key.currency0)).approve(address(bridgeProtocol), bridgeAmount);
        
        try bridgeProtocol.bridge{value: msg.value}(
            Currency.unwrap(key.currency0),
            bridgeAmount,
            venue.chainId,
            swapData.recipient,
            quote.bridgeData
        ) {
            emit CrossChainSwapExecuted(
                sender,
                key.currency0,
                key.currency1,
                uint256(int256(params.amountSpecified)),
                quote.outputAmount,
                venue.chainId,
                venue.venueAddress,
                quote.totalCost,
                keccak256(abi.encodePacked(sender, block.timestamp, key.currency0, key.currency1))
            );
        } catch {
            IERC20(Currency.unwrap(key.currency0)).transfer(sender, bridgeAmount);
            if (protocolFee > 0) {
                IERC20(Currency.unwrap(key.currency0)).transferFrom(feeRecipient, sender, protocolFee);
            }
            revert("Bridge execution failed");
        }
    }

    /// @notice Validate swap data
    function _validateSwapData(CrossChainSwapData memory swapData) internal view {
        if (swapData.recipient == address(0)) revert ZeroAddress();
        if (swapData.deadline <= block.timestamp) revert SwapExpired();
        if (swapData.thresholdBps > 1000) revert InvalidThresholdParameters();
    }

    /// @notice Check if new quote is better than current best
    function _isBetterQuote(ExecutionQuote memory newQuote, ExecutionQuote memory currentBest) 
        internal 
        pure 
        returns (bool) 
    {
        if (currentBest.netOutput == 0) return newQuote.netOutput > 0;
        if (newQuote.netOutput == 0) return false;
        
        uint256 newScore = newQuote.netOutput * newQuote.confidenceScore;
        uint256 currentScore = currentBest.netOutput * currentBest.confidenceScore;
        
        return newScore > currentScore;
    }

    /// @notice Calculate confidence score from price data
    function _calculateConfidenceScore(
        IPythOracle.Price memory priceIn,
        IPythOracle.Price memory priceOut
    ) internal pure returns (uint8) {
        uint256 priceInConf = uint256(priceIn.conf) * 10000 / uint256(int256(priceIn.price));
        uint256 priceOutConf = uint256(priceOut.conf) * 10000 / uint256(int256(priceOut.price));
        
        uint256 avgConfidence = (priceInConf + priceOutConf) / 2;
        
        if (avgConfidence > 500) return 20;
        if (avgConfidence > 200) return 50;
        if (avgConfidence > 100) return 70;
        if (avgConfidence > 50) return 85;
        return 95;
    }

    // Admin functions
    function addVenue(
        uint256 chainId,
        address venueAddress,
        string memory name,
        uint256 gasEstimate
    ) external onlyOwner {
        _addVenue(chainId, venueAddress, name, gasEstimate, 80);
    }

    function _addVenue(
        uint256 chainId,
        address venueAddress,
        string memory name,
        uint256 gasEstimate,
        uint8 reliabilityScore
    ) internal {
        if (venueAddress == address(0)) revert ZeroAddress();
        
        venues[venueCount] = SwapVenue({
            chainId: chainId,
            venueAddress: venueAddress,
            name: name,
            isActive: true,
            baseGasEstimate: gasEstimate,
            lastUpdateTime: block.timestamp,
            reliabilityScore: reliabilityScore
        });
        
        supportedChains[chainId] = true;
        
        emit VenueConfigured(chainId, venueAddress, name, gasEstimate, true);
        
        venueCount++;
    }

    function updateVenueStatus(uint256 venueIndex, bool isActive) external onlyOwner {
        if (venueIndex >= venueCount) revert InvalidVenueIndex();
        
        venues[venueIndex].isActive = isActive;
        venues[venueIndex].lastUpdateTime = block.timestamp;
        
        emit VenueConfigured(
            venues[venueIndex].chainId,
            venues[venueIndex].venueAddress,
            venues[venueIndex].name,
            venues[venueIndex].baseGasEstimate,
            isActive
        );
    }

    function configurePriceData(
        address token,
        bytes32 priceId,
        uint256 maxStaleness
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (maxStaleness == 0) maxStaleness = defaultPriceStaleness;
        
        tokenPriceData[token] = PriceData({
            priceId: priceId,
            lastUpdateTime: block.timestamp,
            maxStaleness: maxStaleness,
            isActive: true
        });
    }

    function updatePythOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        
        address oldOracle = address(pythOracle);
        pythOracle = IPythOracle(newOracle);
        
        emit PriceOracleUpdated(oldOracle, newOracle);
    }

    function updateBridgeProtocol(address newBridge) external onlyOwner {
        if (newBridge == address(0)) revert ZeroAddress();
        
        address oldBridge = address(bridgeProtocol);
        bridgeProtocol = IBridgeProtocol(newBridge);
        
        emit BridgeProtocolUpdated(oldBridge, newBridge);
    }

    function updateSwapParameters(
        uint256 _maxSlippageBps,
        uint256 _bridgeSlippageBps,
        uint256 _minBridgeAmount,
        uint256 _crossChainThresholdBps
    ) external onlyOwner {
        if (_maxSlippageBps > 1000 || _bridgeSlippageBps > 500) revert InvalidSlippageParameters();
        if (_crossChainThresholdBps > 1000) revert InvalidThresholdParameters();
        
        maxSlippageBps = _maxSlippageBps;
        bridgeSlippageBps = _bridgeSlippageBps;
        minBridgeAmount = _minBridgeAmount;
        crossChainThresholdBps = _crossChainThresholdBps;
        
        emit SwapParametersUpdated(_maxSlippageBps, _bridgeSlippageBps, _minBridgeAmount);
    }

    function updateFeeParameters(
        address _feeRecipient,
        uint256 _protocolFeeBps
    ) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_protocolFeeBps > 100) revert("Fee too high");
        
        feeRecipient = _feeRecipient;
        protocolFeeBps = _protocolFeeBps;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        
        IERC20(token).transfer(recipient, amount);
        
        emit EmergencyWithdraw(token, amount, recipient);
    }

    // View functions
    function getVenueInfo(uint256 venueIndex) external view returns (SwapVenue memory) {
        if (venueIndex >= venueCount) revert InvalidVenueIndex();
        return venues[venueIndex];
    }

    function getAllActiveVenues() external view returns (SwapVenue[] memory activeVenues) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < venueCount; i++) {
            if (venues[i].isActive) activeCount++;
        }
        
        activeVenues = new SwapVenue[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < venueCount; i++) {
            if (venues[i].isActive) {
                activeVenues[index] = venues[i];
                index++;
            }
        }
        
        return activeVenues;
    }

    function simulateSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        CrossChainSwapData memory swapData
    ) external view returns (ExecutionQuote memory bestQuote, ExecutionQuote[] memory allQuotes) {
        bestQuote = _getBestExecutionVenue(key, params, swapData);
        
        allQuotes = new ExecutionQuote[](venueCount);
        for (uint256 i = 0; i < venueCount; i++) {
            if (venues[i].isActive) {
                allQuotes[i] = _getVenueQuote(key, params, venues[i], i, swapData);
            }
        }
        
        return (bestQuote, allQuotes);
    }

    function getTokenPriceData(address token) external view returns (PriceData memory) {
        return tokenPriceData[token];
    }

    function isChainSupported(uint256 chainId) external view returns (bool) {
        return supportedChains[chainId];
    }

    // Utility functions
    function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable {
        pythOracle.updatePriceFeeds{value: msg.value}(priceUpdateData);
    }

    receive() external payable {}
}