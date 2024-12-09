//SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

abstract contract Controller is OwnableUpgradeable, PausableUpgradeable {
    function __Controller_init_() internal onlyInitializing {
        __Ownable_init();
        __Pausable_init();
    }

    function adminPause() external onlyOwner {
        _pause();
    }

    function adminUnPause() external onlyOwner {
        _unpause();
    }
}
