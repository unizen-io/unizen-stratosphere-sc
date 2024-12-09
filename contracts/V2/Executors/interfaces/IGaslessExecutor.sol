pragma solidity >=0.8.0;

interface IGaslessExecutor {
    function isValidSender(address sender) external view returns (bool);

    struct UnizenGasLessOrder {
        address user;
        address receiver;
        address srcToken;
        address dstToken;
        uint256 amountIn;
        uint256 fee;
        uint256 amountOutMin;
        uint256 deadline;
        bytes32 tradeHash;
    }

    event GasLessSwapped(address indexed user, address srcToken, address dstToken, uint256 amountIn, uint256 amountOut);
}
