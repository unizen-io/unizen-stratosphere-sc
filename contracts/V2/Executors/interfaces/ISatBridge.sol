pragma solidity >=0.8.0;

interface ISatBridge {
    function lock(address token, address user, uint256 destChainId, uint256 amount) external;

    function unLock(address token, address user, bytes32 sourceTxHash, uint256 amount) external;

    function setRouter(address newRouter) external;
}
