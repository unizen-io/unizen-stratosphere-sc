// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DexHelper
 * @notice This contract manages whitelisting of DEXes and their functions, allowing only verified addresses
 * and functions to be used. It also includes roles for the controller and developer.
 * @dev The contract owner can set the developer address, and the developer can whitelist or remove DEXes and their functions.
 */
contract DexHelper is Ownable {
    struct FunctionSign {
        bytes4[] selectors; // Function selectors for whitelisting DEX functions
    }

    /// @notice Address of the developer who has special permissions to manage DEXes and functions.
    address public dev;

    /// @notice Mapping to verify if an address is a whitelisted DEX.
    mapping(address => bool) public _isVerified;

    /// @notice Mapping to check if a specific function of a DEX is whitelisted.
    mapping(address => mapping(bytes4 => bool)) public isWhiteListedFunction;

    /// @dev Modifier to restrict certain functions to the developer only.
    modifier onlyDev() {
        require(msg.sender == dev, "Unizen: Not-dev");
        _;
    }

    /**
     * @notice Constructor to initialize the contract.
     */
    constructor() Ownable() {
        dev = msg.sender;
    }

    /**
     * @notice Allows the contract owner to set the developer address.
     * @param _dev The address of the new developer.
     */
    function setDev(address _dev) external onlyOwner {
        dev = _dev;
    }

    /**
     * @notice Whitelists a list of DEXes and their functions.
     * @dev Only the developer can call this function. It updates the `_isVerified` mapping for each DEX
     * and the `isWhiteListedFunction` mapping for each function of the DEX.
     * @param dexes The list of DEX addresses to whitelist.
     * @param funSigns The function signatures to whitelist for each DEX.
     */
    function whitelistDexes(address[] calldata dexes, FunctionSign[] calldata funSigns) external onlyDev {
        for (uint i = 0; i < dexes.length; i++) {
            _isVerified[dexes[i]] = true;
            for (uint j = 0; j < funSigns[i].selectors.length; j++) {
                isWhiteListedFunction[dexes[i]][funSigns[i].selectors[j]] = true;
            }
        }
    }

    /**
     * @notice Removes a list of DEXes from the whitelist.
     * @dev Only the developer can call this function. It sets the `_isVerified` mapping to false for each DEX.
     * @param dexes The list of DEX addresses to remove from the whitelist.
     */
    function removeDexes(address[] calldata dexes) external onlyDev {
        for (uint i = 0; i < dexes.length; i++) {
            _isVerified[dexes[i]] = false;
        }
    }

    /**
     * @notice Adds or removes function selectors for a specific DEX.
     * @dev Only the developer can call this function. It updates the `isWhiteListedFunction` mapping for a given DEX.
     * @param dex The address of the DEX.
     * @param _selectors The list of function selectors to add or remove.
     * @param isAdd Whether to add (`true`) or remove (`false`) the selectors.
     */
    function addOrRemoveFuncSign(address dex, bytes4[] calldata _selectors, bool isAdd) external onlyDev {
        require(_isVerified[dex], "Unizen: Invalid-dex");
        for (uint i = 0; i < _selectors.length; i++) {
            isWhiteListedFunction[dex][_selectors[i]] = isAdd;
        }
    }

    /**
     * @notice Checks if a specific DEX and its function are whitelisted.
     * @dev It checks both the `_isVerified` mapping and the `isWhiteListedFunction` mapping to verify the DEX and function.
     * @param _exchangeAddr The address of the DEX.
     * @param selector The function selector to check.
     * @return Returns `true` if the DEX and its function are whitelisted, otherwise `false`.
     */
    function isWhiteListedDex(address _exchangeAddr, bytes4 selector) public view returns (bool) {
        if (!_isVerified[_exchangeAddr]) return false;
        return isWhiteListedFunction[_exchangeAddr][selector];
    }
}
