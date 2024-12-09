pragma solidity >=0.8.0;

interface IDexHelpers {
    function isWhiteListedDex(address _exchangeAddr, bytes4 selector) external view returns (bool);
}
