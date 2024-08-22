// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "../interfaces/IController.sol";

abstract contract Controller is
    OwnableUpgradeable,
    PausableUpgradeable,
    IController
{
    mapping(address => bool) private _isVerified;

    function __Controller_init_() internal onlyInitializing {
        __Ownable_init();
        __Pausable_init();
    }

    function whiteListDex(address _exchangeAddr, bool _verification)
        external
        override
        onlyOwner
        returns (bool)
    {
        require(_exchangeAddr != address(0), "Zero-address");
        _isVerified[_exchangeAddr] = _verification;
        return (_verification);
    }

    function whiteListDexes(
        address[] memory _dexes,
        bool[] memory _verifications
    ) external onlyOwner {
        for (uint8 i = 0; i < _dexes.length; i++) {
            require(_dexes[i] != address(0), "Zero-address");
            _isVerified[_dexes[i]] = _verifications[i];
        }
    }

    function adminPause() external override onlyOwner {
        _pause();
    }

    function adminUnPause() external override onlyOwner {
        _unpause();
    }

    function isWhiteListedDex(address _exchangeAddr)
        public
        view
        override
        returns (bool)
    {
        return _isVerified[_exchangeAddr];
    }
}
