pragma solidity ^0.8.12;
interface IMeson {
    function postSwapFromContract(uint256 encodedSwap, uint200 postingValue, address fromContract) external payable;
}
