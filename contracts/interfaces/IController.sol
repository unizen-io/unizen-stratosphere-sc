// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;
interface IController {
    function whiteListDex(address, bool) external returns(bool);
    function adminPause() external; 
    function adminUnPause() external;
    function isWhiteListedDex(address) external returns(bool);
}