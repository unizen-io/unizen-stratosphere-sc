// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {EthReceiver} from "../../helpers/EthReceiver.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IDexHelpers} from "./interfaces/IDexHelpers.sol";
import {Types} from "./interfaces/Types.sol";

/**
 * @title BaseExecutor
 * @dev Abstract contract providing base functions for executing token swaps, handling fees, and recovering assets.
 */
abstract contract BaseExecutor is OwnableUpgradeable, ReentrancyGuardUpgradeable, EthReceiver, Types {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /// @notice Address of the Unizen Router
    address public unizenRouter;

    /// @notice Address of the DexHelper contract
    address public dexHelper;

    /// @notice Mapping of earned fees of Unizen for each token
    mapping(address => uint) public unizenFeeEarned;

    /**
     * @notice Ensures that only the Unizen Router can call the function
     */
    modifier onlyRouter() {
        require(msg.sender == unizenRouter, "Unizen: Invalid-router");
        _;
    }

    /**
     * @notice Initializes the contract with router, and DexHelper addresses
     * @param _router Address of the Unizen Router
     * @param _dexHelper Address of the DexHelper contract
     */
    function __BaseExecutor_init(address _router, address _dexHelper) internal onlyInitializing {
        __ReentrancyGuard_init();
        __Ownable_init();
        unizenRouter = _router;
        dexHelper = _dexHelper;
    }

    /**
     * @notice Updates the DexHelper address
     * @param _dexHelper New DexHelper address
     */
    function setDexHelper(address _dexHelper) external onlyOwner {
        dexHelper = _dexHelper;
    }

    /**
     * @notice Updates the Unizen Router address
     * @param _unizenRouter New Unizen Router address
     */
    function setRouter(address _unizenRouter) external onlyOwner {
        unizenRouter = _unizenRouter;
    }

    /**
     * @notice Revokes token approval for a given spender
     * @param token Address of the token to revoke approval for
     * @param spender Address of the spender to revoke approval from
     */
    function revokeApprove(address token, address spender) external onlyOwner {
        IERC20(token).safeApprove(spender, 0);
    }

    /**
     * @notice Collects the integrator fee from a trade and updates the Unizen fee earned
     * send fee directy to integrator
     * @param isETHTrade Indicates if the trade involves ETH
     * @param token The token involved in the trade
     * @param feeReceiver Address to receive the fee of Integrator
     * @param amount Total amount from which the fee is calculated
     * @param feePercent Percentage of the total amount to take as fee (basis points)
     * @param sharePercent Percentage of the fee to allocate to Unizen (basis points)
     * @return totalFee The total fee collected
     */
    function _takeIntegratorFee(
        bool isETHTrade,
        IERC20 token,
        address feeReceiver,
        uint256 amount,
        uint256 feePercent,
        uint256 sharePercent
    ) internal returns (uint256 totalFee) {
        totalFee = (amount * feePercent) / 10000;
        // Check if sharePercent is not 100%, so totalFee - (totalFee * sharePercent) / 10000 is higher than 0
        // Only transfer higher than 0 value
        // If sharePercent is 10000, meaning all fee earned by Unizen, so no need to transfer
        if (sharePercent < 10000) {
            if (isETHTrade) {
                payable(feeReceiver).sendValue(totalFee - (totalFee * sharePercent) / 10000);
            } else {
                token.safeTransfer(feeReceiver, totalFee - (totalFee * sharePercent) / 10000);
            }
        }
        if (sharePercent > 0) {
            require(sharePercent <= 10000, "Unizen: Invalid-share-number");
            unizenFeeEarned[address(token)] = unizenFeeEarned[address(token)] + (totalFee * sharePercent) / 10000;
        }
        return totalFee;
    }

    /**
     * @notice Unizen withdraws the earned fees to a receiver
     * @param receiver Address to receive the fees
     * @param tokens List of tokens to withdraw fees
     */
    function unizenWithdrawEarnedFee(address payable receiver, address[] calldata tokens) external onlyRouter {
        for (uint256 i; i < tokens.length; i++) {
            if (unizenFeeEarned[tokens[i]] > 0) {
                IERC20(tokens[i]).safeTransfer(receiver, unizenFeeEarned[tokens[i]]);
                unizenFeeEarned[tokens[i]] = 0;
            }
        }

        if (unizenFeeEarned[address(0)] > 0) {
            (bool success, ) = receiver.call{value: unizenFeeEarned[address(0)]}("");
            require(success, "Unizen: Withdraw-native-failed");
            unizenFeeEarned[address(0)] = 0;
        }
    }

    /**
     * @notice Recovers tokens or ETH from the contract
     * @param token Address of the token to recover (address(0) for ETH)
     */
    function recoverAsset(address token) external onlyOwner {
        if (token == address(0)) {
            payable(msg.sender).sendValue(address(this).balance);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(msg.sender, balance);
        }
    }

    /**
     * @notice Transfers tokens using a router with or without a permit
     * @param permit Permit data for token transfer
     * @param token Address of the token to transfer
     * @param user Address of the user
     * @param amount Amount of tokens to transfer
     */
    function _routerTransferTokens(Permit calldata permit, address token, address user, uint256 amount) internal {
        if (permit.user != address(0)) {
            require(permit.user == user, "Unizen: Permit-user-does-not-match");
            require(permit.amount >= amount, "Unizen: Invalid-permit-amount");
            IRouter(unizenRouter).routerTransferTokensPermit2(
                token,
                permit.amount,
                permit.nonce,
                permit.deadline,
                user,
                permit.sign
            );
        } else {
            IRouter(unizenRouter).routerTransferTokens(token, user, amount);
        }
    }

    /**
     * @notice Executes a token swap across multiple exchanges, pools
     * @param _srcToken The source token address
     * @param _srcAmount The amount of source token to swap
     * @param calls Array of swap call data
     * @param isDstChainSwap Boolean indicating if the swap is on destination chain of cross-chain trade
     */
    function _swap(address _srcToken, uint256 _srcAmount, SwapCall[] calldata calls, bool isDstChainSwap) internal {
        require(calls[0].sellToken == _srcToken, "Unizen: Invalid-token");
        uint256 tempAmount;
        uint256 totalSrcAmount;
        IERC20 srcToken;
        for (uint8 i = 0; i < calls.length; ) {
            require(
                isValidDexAndFunction(calls[i].targetExchange, getFunctionSelector(calls[i].data)),
                "Unizen: Not-verified-dex"
            );
            if (calls[i].sellToken == _srcToken) {
                totalSrcAmount += calls[i].amount;
                require(totalSrcAmount <= _srcAmount, "Unizen: Invalid-amount-to-sell");
            }
            if (calls[i].sellToken == address(0) && !isDstChainSwap) {
                tempAmount = _executeTrade(
                    calls[i].targetExchange,
                    address(0),
                    calls[i].buyToken,
                    calls[i].amount,
                    calls[i].amount,
                    calls[i].data
                );
            } else {
                srcToken = IERC20(calls[i].sellToken);
                srcToken.safeApprove(calls[i].targetExchange, 0);
                srcToken.safeApprove(calls[i].targetExchange, calls[i].amount);

                tempAmount = _executeTrade(
                    calls[i].targetExchange,
                    calls[i].sellToken,
                    calls[i].buyToken,
                    calls[i].amount,
                    0,
                    calls[i].data
                );
                srcToken.safeApprove(calls[i].targetExchange, 0);
            }
            if (i != calls.length - 1 && calls[i + 1].sellToken != _srcToken) {
                require(tempAmount >= calls[i + 1].amount, "Unizen: Slippage");
                require(calls[i].buyToken == calls[i + 1].sellToken, "Unizen: Invalid-token");
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Executes a trade on a specific exchange, pool
     * @param _targetExchange Address of the target exchange/pool
     * @param sellToken The token being sold
     * @param buyToken The token being bought
     * @param sellAmount Amount of sell token
     * @param _nativeAmount Amount of native token (ETH)
     * @param _data Encoded call data for the trade at _targetExchange
     * @return The amount of buy token received
     */
    function _executeTrade(
        address _targetExchange,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 _nativeAmount,
        bytes memory _data
    ) internal returns (uint256) {
        uint256 balanceBeforeTrade = _getBalance(sellToken);
        uint256 balanceBuyTokenBefore = _getBalance(buyToken);
        (bool success, ) = _targetExchange.call{value: _nativeAmount}(_data);
        require(success, "Unizen: Call-Failed");
        uint256 balanceAfterTrade = _getBalance(sellToken);
        require(balanceAfterTrade >= balanceBeforeTrade - sellAmount, "Unizen: Some-one-steal-fund");
        uint256 balanceBuyTokenAfter = _getBalance(buyToken);
        return (balanceBuyTokenAfter - balanceBuyTokenBefore);
    }

    /**
     * @notice Transfer token to a user
     * @param token The token to transfer (address(0) for ETH)
     * @param to The address of the recipient
     * @param amount The amount of tokens to transfer
     */
    function _transferTokenToUser(address token, address to, uint256 amount) internal {
        if (token != address(0)) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            payable(to).sendValue(amount);
        }
    }

    /**
     * @notice Obtains source tokens from the user and handles fee deduction
     * @param user Address of the user
     * @param srcToken Address of the source token
     * @param srcTokenAmt Amount of source tokens to obtain
     * @param nativeFee Native fee for checking amount enough for cross-chain trade
     * @param integrator Integrator fee structure
     * @param permit Permit data for token transfer
     * @return swapAmount The amount available for swapping after fees
     */
    function _obtainSrcTokenFromUser(
        address user,
        address srcToken,
        uint256 srcTokenAmt,
        uint256 nativeFee,
        Integrator calldata integrator,
        Permit calldata permit
    ) internal returns (uint256 swapAmount) {
        bool isFromNative = srcToken == address(0);

        if (isFromNative) {
            require(msg.value >= srcTokenAmt + nativeFee, "Unizen: Invalid-amount");
        } else {
            require(msg.value >= nativeFee, "Unizen: Not-enough-fee");
            _routerTransferTokens(permit, srcToken, user, srcTokenAmt);
        }

        if (integrator.feePercent > 0) {
            srcTokenAmt =
                srcTokenAmt -
                _takeIntegratorFee(
                    isFromNative,
                    IERC20(srcToken),
                    integrator.feeReceiver,
                    srcTokenAmt,
                    integrator.feePercent,
                    integrator.sharePercent
                );
        }

        swapAmount = srcTokenAmt;
    }

    /**
     * @notice Retrieves the balance of a given token
     * @param _token The address of the token
     * @return The token balance (or ETH balance if address(0))
     */
    function _getBalance(address _token) internal view returns (uint256) {
        if (_token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(_token).balanceOf(address(this));
        }
    }

    /**
     * @notice Extracts the function selector from the call data
     * @param call The call data
     * @return selector The function selector
     */
    function getFunctionSelector(bytes calldata call) internal pure returns (bytes4 selector) {
        selector = bytes4(call[:4]);
    }

    /**
     * @notice Validates if a DEX and function are whitelisted
     * @param dex The DEX address
     * @param selector The function selector
     * @return isValid Boolean indicating if the DEX and function are valid
     */
    function isValidDexAndFunction(address dex, bytes4 selector) internal view returns (bool) {
        return IDexHelpers(dexHelper).isWhiteListedDex(dex, selector);
    }
}
