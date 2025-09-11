// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Interface for cross-chain bridge protocol
interface IBridgeProtocol {
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

    struct BridgeTransaction {
        bytes32 transactionId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        address token;
        uint256 amount;
        address recipient;
        BridgeStatus status;
        uint256 initiatedAt;
        uint256 completedAt;
    }

    enum BridgeStatus {
        Pending,
        InProgress,
        Completed,
        Failed,
        Cancelled
    }

    struct ProtocolInfo {
        string name;
        string version;
        uint256[] supportedChains;
        mapping(uint256 => address[]) supportedTokens;
        mapping(uint256 => uint256) baseFees;
        uint8 securityScore;
    }

    // Get bridge quote
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 destinationChainId
    ) external view returns (BridgeQuote memory quote);

    // Get batch quotes
    function getBatchQuotes(
        address tokenIn,
        address tokenOut,
        uint256[] calldata amounts,
        uint256 destinationChainId
    ) external view returns (BridgeQuote[] memory quotes);

    // Execute bridge transaction
    function bridge(
        address tokenIn,
        uint256 amountIn,
        uint256 destinationChainId,
        address recipient,
        bytes calldata bridgeData
    ) external payable returns (bytes32 transactionId);

    // Execute bridge with parameters
    function bridgeWithParams(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 destinationChainId,
        address recipient,
        uint256 deadline,
        bytes calldata bridgeData
    ) external payable returns (bytes32 transactionId);

    // Get bridge transaction status
    function getBridgeTransaction(bytes32 transactionId) 
        external 
        view 
        returns (BridgeTransaction memory transaction);

    // Get user transactions
    function getUserTransactions(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (BridgeTransaction[] memory transactions);

    // Estimate gas cost
    function estimateGas(
        address tokenIn,
        uint256 amountIn,
        uint256 destinationChainId
    ) external view returns (uint256 gasEstimate);

    // Check if token is supported
    function isTokenSupported(address token, uint256 chainId) 
        external 
        view 
        returns (bool supported);

    // Get supported tokens for chain
    function getSupportedTokens(uint256 chainId) 
        external 
        view 
        returns (address[] memory tokens);

    // Get all supported chains
    function getSupportedChains() external view returns (uint256[] memory chains);

    // Get bridge limits
    function getBridgeLimits(address token, uint256 chainId) 
        external 
        view 
        returns (uint256 minAmount, uint256 maxAmount);

    // Get bridge fees
    function getBridgeFees(address tokenIn, uint256 destinationChainId) 
        external 
        view 
        returns (uint256 baseFee, uint256 percentageFee);

    // Retry failed bridge
    function retryBridge(bytes32 transactionId) 
        external 
        payable 
        returns (bytes32 newTransactionId);

    // Cancel bridge transaction
    function cancelBridge(bytes32 transactionId) external returns (bool success);

    event BridgeInitiated(
        bytes32 indexed transactionId,
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        uint256 amountIn,
        uint256 destinationChainId,
        uint256 estimatedOutput
    );

    event BridgeCompleted(
        bytes32 indexed transactionId,
        address indexed recipient,
        address tokenOut,
        uint256 amountOut,
        uint256 actualTime
    );

    event BridgeFailed(
        bytes32 indexed transactionId,
        string reason,
        bool refunded
    );

    event FeesUpdated(
        uint256 indexed chainId,
        address indexed token,
        uint256 baseFee,
        uint256 percentageFee
    );

    event ChainAdded(
        uint256 indexed chainId,
        string name,
        address[] supportedTokens
    );

    event ChainRemoved(
        uint256 indexed chainId
    );

    event ProtocolUpdated(
        string parameter,
        bytes oldValue,
        bytes newValue
    );
}