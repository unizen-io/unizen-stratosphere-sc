// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {EthReceiver} from "../../helpers/EthReceiver.sol";
import {ISingleChainExecutor} from "./interfaces/ISingleChainExecutor.sol";
import {BaseExecutor} from "./BaseExecutor.sol";

/**
 * @title SingleChainExecutor
 * @notice This contract facilitates token swaps on a single blockchain using various methods.
 * @dev It extends the BaseExecutor and implements ISingleChainExecutor interface.
 */
contract SingleChainExecutor is ISingleChainExecutor, BaseExecutor {
    using SafeERC20 for IERC20;

    /**
     * @notice Initializes the SingleChainExecutor contract.
     * @param _router The address of the router contract.
     * @param _dexHelper The address of the DexHelper contract.
     */
    function initialize(address _router, address _dexHelper) external initializer {
        __SingleChainExecutor_init(_router, _dexHelper);
    }

    /**
     * @dev Internal initialization function to set up the contract state.
     * @param _router The address of the router contract.
     * @param _dexHelper The address of the DexHelper contract.
     */
    function __SingleChainExecutor_init(address _router, address _dexHelper) internal onlyInitializing {
        __BaseExecutor_init(_router, _dexHelper);
    }

    /**
     * @notice Executes a token swap where the amount of tokens received is specified.
     * @param info Information about the swap, including user, tokens, amounts, and integrator.
     * @param calls An array of SwapCall structs representing the swap execution steps.
     * @param permit Permit data for token transfer.
     * @dev Ensures that the receiver address is valid, obtains source tokens from the user,
     * executes the swap, and transfers the resulting tokens to the receiver.
     */
    function swapExactOut(
        SwapExactOutInfo calldata info,
        SwapCall[] calldata calls,
        Permit calldata permit
    ) external payable override onlyRouter nonReentrant {
        require(info.receiver != address(0), "Unizen: Invalid-receiver");
        uint256 amountTakenIn = _obtainSrcTokenFromUser(
            info.user,
            info.srcToken,
            info.amountInMax,
            0,
            info.integrator,
            permit
        );
        ContractBalance memory contractBalance = ContractBalance(0, 0, 0, 0, 0);
        contractBalance.balanceSrcBefore = _getBalance(info.srcToken);
        contractBalance.balanceDstBefore = _getBalance(info.dstToken);
        // execute trade logic
        _swap(info.srcToken, amountTakenIn, calls, false);
        contractBalance.balanceDstAfter = _getBalance(info.dstToken);
        contractBalance.totalDstAmount = contractBalance.balanceDstAfter - contractBalance.balanceDstBefore;
        require(contractBalance.totalDstAmount >= info.amountOut, "Unizen: Return-amount-is-not-enough");
        _transferTokenToUser(info.dstToken, info.receiver, contractBalance.totalDstAmount);
        contractBalance.balanceSrcAfter = _getBalance(info.srcToken);
        uint256 diff = contractBalance.balanceSrcAfter + amountTakenIn - contractBalance.balanceSrcBefore; // remaining funds from to be sent back
        if (diff > 0) {
            _transferTokenToUser(info.srcToken, info.user, diff);
        }
        emit Swapped(
            info.user,
            info.amountInMax, // actual swapped amount
            contractBalance.totalDstAmount,
            info.srcToken,
            info.dstToken,
            info.apiId
        );
    }

    /**
     * @notice Executes a token swap where the amount of tokens sent is specified.
     * @param info Information about the swap, including user, tokens, amounts, and integrator.
     * @param calls An array of SwapCall structs representing the swap execution steps.
     * @param permit Permit data for token transfer.
     * @dev Ensures that the receiver address is valid, obtains source tokens from the user,
     * executes the swap, and transfers the resulting tokens to the receiver.
     */
    function swap(
        SwapExactInInfo calldata info,
        SwapCall[] calldata calls,
        Permit calldata permit
    ) external payable onlyRouter nonReentrant {
        require(info.receiver != address(0), "Unizen: Invalid-receiver");
        // if trade native, when call executor, router already sent native value together
        uint256 amount = _obtainSrcTokenFromUser(info.user, info.srcToken, info.amountIn, 0, info.integrator, permit);
        uint256 balanceDstBefore = _getBalance(info.dstToken);
        // execute trade logic
        _swap(info.srcToken, amount, calls, false);
        uint256 balanceDstAfter = _getBalance(info.dstToken);
        uint256 totalDstAmount = balanceDstAfter - balanceDstBefore;
        require(totalDstAmount >= info.amountOutMin, "Unizen: Return-amount-is-not-enough");
        _transferTokenToUser(info.dstToken, info.receiver, totalDstAmount);
        emit Swapped(info.user, info.amountIn, totalDstAmount, info.srcToken, info.dstToken, info.apiId);
    }

    /**
     * @notice Executes a simple token swap at a specified DEX that supporting send token directly to user (receiver)
     * @param info Information about the swap, including user, tokens, amounts, and integrator.
     * @param call The SwapCall struct representing the swap execution step.
     * @param permit Permit data for token transfer.
     * @dev Ensures that the receiver address is valid, obtains source tokens from the user,
     * verifies the DEX, executes the swap, and transfers the resulting tokens to the receiver.
     */
    function swapSimple(
        SwapExactInInfo calldata info,
        SwapCall calldata call,
        Permit calldata permit
    ) external payable onlyRouter nonReentrant {
        bool tradeToNative = info.dstToken == address(0) ? true : false;
        IERC20 srcToken = IERC20(info.srcToken);
        IERC20 dstToken = IERC20(info.dstToken);
        require(info.receiver != address(0), "Unizen: Invalid-receiver");
        uint256 amount = _obtainSrcTokenFromUser(info.user, info.srcToken, info.amountIn, 0, info.integrator, permit);
        require(amount >= call.amount, "Unizen: Invalid-amount-trade");
        uint256 balanceUserBefore = tradeToNative ? address(info.receiver).balance : dstToken.balanceOf(info.receiver);
        {
            bool success;
            require(
                isValidDexAndFunction(call.targetExchange, getFunctionSelector(call.data)),
                "Unizen: Not-verified-dex"
            );
            // our trade logic here is trade at a single dex and that dex will send amount of dstToken to user directly
            // dex not send token to this contract as we want to save 1 ERC20/native transfer for user
            // we only send call.amount and approve max amount to trade if erc20 is amount, already checked above
            if (msg.value > 0 && info.srcToken == address(0)) {
                // trade ETH
                (success, ) = call.targetExchange.call{value: call.amount}(call.data);
            } else {
                // trade ERC20
                srcToken.safeApprove(call.targetExchange, 0);
                srcToken.safeApprove(call.targetExchange, amount);
                (success, ) = call.targetExchange.call(call.data);
                srcToken.safeApprove(call.targetExchange, 0);
            }
            require(success, "Unizen: Trade-failed");
        }
        uint256 balanceUserAfter = tradeToNative ? address(info.receiver).balance : dstToken.balanceOf(info.receiver);
        // use amount as memory variables to not declare another one
        amount = balanceUserAfter - balanceUserBefore;
        require(amount >= info.amountOutMin, "Unizen: INSUFFICIENT-OUTPUT-AMOUNT");
        emit Swapped(info.user, info.amountIn, amount, info.srcToken, info.dstToken, info.apiId);
    }
}
