// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ZCXBurn is Ownable {
    using SafeERC20 for ERC20Burnable;

    address public ZCX;
    uint256 public totalBurnt;

    event BurnZCX(uint256 indexed amount);

    constructor(address zcx) {
        ZCX = zcx;
    }

    function fundZCX(uint256 amount) external onlyOwner {
        ERC20Burnable(ZCX).safeTransferFrom(msg.sender, address(this), amount);
    }

    function recoverAsset(address token) external onlyOwner {
        if (token == address(0)) {
            payable(msg.sender).transfer(address(this).balance);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            ERC20Burnable(token).transfer(msg.sender, balance);
        }
    }

    function burnZCX(uint256 amount) external onlyOwner {
        ERC20Burnable(ZCX).burn(amount);
        totalBurnt += amount;
        emit BurnZCX(amount);
    }
}
