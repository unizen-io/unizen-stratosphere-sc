// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EthReceiver} from "../../helpers/EthReceiver.sol";
import {IStargateRouter} from "../../interfaces/IStargateRouter.sol";
import {IStargateReceiver} from "../../interfaces/IStargateReceiver.sol";
import {ITcRouter} from "../../interfaces/ITcRouter.sol";
import {IStargateThorchainExecutor} from "./interfaces/IStargateThorchainExecutor.sol";
import {BaseExecutor} from "./BaseExecutor.sol";

/**
 * @title StargateThorchainExecutor
 * @notice This contract executes cross-chain swaps using the Stargate and Thorchain protocols.
 * @dev It implements the IStargateThorchainExecutor, BaseExecutor, and IStargateReceiver interfaces.
 */
contract StargateThorchainExecutor is IStargateThorchainExecutor, BaseExecutor, IStargateReceiver {
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public stargateRouter; // The Stargate router address.
    mapping(uint16 => address) public destAddr; // Mapping of destination chain IDs to addresses.
    mapping(uint16 => address) public poolToStableAddr; // Mapping of pool IDs to stable token addresses.
    mapping(address => bool) public stargateAddr; // Mapping of valid Stargate addresses.
    address public tcRouter; // The Thorchain router address.

    /**
     * @notice Initializes the StargateThorchainExecutor contract.
     * @param _router The address of the router contract.
     * @param _stargateRouter The address of the Stargate router.
     * @param _tcRouter The address of the Thorchain router.
     * @param _dexHelper The address of the DEX helper contract.
     */
    function initialize(
        address _router,
        address _stargateRouter,
        address _tcRouter,
        address _dexHelper
    ) external initializer {
        __StargateThorchainExecutor_init(_router, _dexHelper);
        stargateRouter = _stargateRouter;
        tcRouter = _tcRouter;
    }

    /**
     * @dev Internal initialization function to set up the contract state.
     * @param _router The address of the router contract.
     * @param _dexHelper The address of the DEX helper contract.
     */
    function __StargateThorchainExecutor_init(address _router, address _dexHelper) internal onlyInitializing {
        __BaseExecutor_init(_router, _dexHelper);
    }

    /**
     * @notice Sets the validity of a Stargate address.
     * @param _stgAddr The address of the Stargate contract.
     * @param isValid A boolean indicating if the address is valid.
     * @dev Can only be called by the contract owner.
     */
    function setStargateAddr(address _stgAddr, bool isValid) external onlyOwner {
        stargateAddr[_stgAddr] = isValid;
    }

    /**
     * @notice Sets the destination address for a given chain ID.
     * @param chainId The ID of the destination chain.
     * @param dexAggr The address of the DEX aggregator for that chain.
     * @dev Can only be called by the contract owner.
     */
    function setDestAddr(uint16 chainId, address dexAggr) external onlyOwner {
        destAddr[chainId] = dexAggr;
    }

    /**
     * @notice Sets the Stargate router address.
     * @param router The new Stargate router address.
     * @dev Can only be called by the contract owner. Reverts if the address is invalid.
     */
    function setStargateRouter(address router) external onlyOwner {
        require(router != address(0), "Unizen: Invalid-address");
        stargateRouter = router;
    }

    /**
     * @notice Sets the stable token address for a given pool ID.
     * @param poolId The ID of the pool.
     * @param stableAddr The address of the stable token.
     * @dev Can only be called by the contract owner.
     */
    function setPoolStable(uint16 poolId, address stableAddr) external onlyOwner {
        poolToStableAddr[poolId] = stableAddr;
        if (IERC20(stableAddr).allowance(address(this), stargateRouter) == 0) {
            IERC20(stableAddr).safeApprove(stargateRouter, type(uint256).max);
        }
    }

    /**
     * @notice Sets the Thorchain router address.
     * @param _router The new Thorchain router address.
     * @dev Can only be called by the contract owner.
     */
    function setThorChainRouter(address _router) external onlyOwner {
        tcRouter = _router;
    }

    /**
     * @notice Executes a swap on the destination chain.
     * @param _srcToken The address of the source token.
     * @param _srcAmount The amount of source tokens to swap.
     * @param calls An array of SwapCall structs representing the swap execution steps.
     * @dev Can only be called from this contract.
     */
    function executeSwapDstChain(
        address _srcToken,
        uint256 _srcAmount,
        SwapCall[] calldata calls
    ) external nonReentrant {
        require(msg.sender == address(this), "Unizen: Not-unizen");
        _swap(_srcToken, _srcAmount, calls, true);
    }

    /**
     * @notice Executes a cross-chain swap using Stargate.
     * @param info Information about the cross-chain swap.
     * @param calls An array of SwapCall structs representing the swap execution steps on the source chain.
     * @param dstCalls An array of SwapCall structs representing the swap execution steps on the destination chain.
     * @param permit Permit data for token transfer.
     * @dev Ensures that the receiver address is valid and executes the swap logic.
     */
    function swapSTG(
        CrossChainSwapSg memory info,
        SwapCall[] calldata calls,
        SwapCall[] memory dstCalls,
        Permit calldata permit
    ) external payable override nonReentrant onlyRouter {
        require(info.receiver != address(0), "Unizen: Invalid-receiver-address");
        uint256 balanceStableBefore = _getBalance(poolToStableAddr[info.srcPool]);
        if (info.isFromNative) {
            require(
                (msg.value >= info.amount + info.nativeFee) && info.srcToken == address(0),
                "Unizen: Invalid-amount"
            );
        } else {
            _routerTransferTokens(permit, info.srcToken, info.user, info.amount);
            require(msg.value >= info.nativeFee, "Unizen: Not-enough-fee");
        }
        {
            if (info.integrator.feePercent > 0) {
                info.amount =
                    info.amount -
                    _takeIntegratorFee(
                        info.isFromNative,
                        IERC20(info.srcToken),
                        info.integrator.feeReceiver,
                        info.amount,
                        info.integrator.feePercent,
                        info.integrator.sharePercent
                    );
            }
        }
        {
            // execute trade logic
            if (calls.length > 0) {
                _swap(info.srcToken, info.amount, calls, false);
            }
        }

        {
            info.amount = _getBalance(poolToStableAddr[info.srcPool]) - balanceStableBefore;
            {
                _sendCrossChain(
                    info.user,
                    info.dstChain,
                    info.srcPool,
                    info.dstPool,
                    info.nativeFee,
                    info.amount,
                    dstCalls.length == 0 ? info.receiver : destAddr[info.dstChain],
                    info.gasDstChain,
                    dstCalls.length == 0 ? bytes("") : abi.encode(info.receiver, info.dstToken, dstCalls)
                );
            }
            emit StargateCrossChainSwapped(
                info.user,
                info.dstChain,
                poolToStableAddr[info.srcPool],
                info.amount,
                info.apiId
            );
        }
    }

    /**
     * @notice Sends a cross-chain swap request to the Stargate router.
     * @param user The address of the user requesting the swap.
     * @param dstChain The destination chain ID.
     * @param srcPool The source pool ID.
     * @param dstPool The destination pool ID.
     * @param fee The fee for the swap.
     * @param amount The amount of stable tokens to swap.
     * @param to The address to send the swapped tokens to.
     * @param gasDstChain The gas limit for the destination chain.
     * @param payload Additional data for the swap.
     * @dev This function is private and used internally for executing swaps.
     */
    function _sendCrossChain(
        address user,
        uint16 dstChain,
        uint16 srcPool,
        uint16 dstPool,
        uint256 fee,
        uint256 amount,
        address to,
        uint256 gasDstChain,
        bytes memory payload
    ) private {
        IStargateRouter(stargateRouter).swap{value: fee}(
            dstChain,
            srcPool,
            dstPool,
            payable(user),
            amount,
            (amount * 995) / 1000, // protect slippage should be just 0.5% max
            IStargateRouter.lzTxObj(gasDstChain, 0, bytes("")),
            abi.encodePacked(to),
            payload
        );
    }

    /**
     * @notice Receives tokens from the Stargate protocol.
     * @param _chainId The ID of the source chain.
     * @param _srcAddress The address of the source contract.
     * @param _nonce The nonce of the message.
     * @param _token The address of the token being received.
     * @param amountLD The amount of tokens being received.
     * @param payload Additional data for the swap.
     * @dev Validates the message sender and executes the swap logic.
     */
    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        address _token,
        uint256 amountLD,
        bytes memory payload
    ) external override {
        require(msg.sender == address(stargateRouter) || stargateAddr[msg.sender], "Unizen: Only-Stargate-Router");
        require(
            _srcAddress.length == abi.encodePacked(destAddr[_chainId]).length &&
                keccak256(_srcAddress) == keccak256(abi.encodePacked(destAddr[_chainId])),
            "Unizen: Not-Unizen"
        );
        (address user, address dstToken, SwapCall[] memory calls) = abi.decode(payload, (address, address, SwapCall[]));
        ContractBalance memory contractStatus = ContractBalance(0, 0, 0, 0, 0);
        contractStatus.balanceDstBefore = _getBalance(dstToken);
        contractStatus.balanceSrcBefore = _getBalance(_token);
        // execute trade logic
        try this.executeSwapDstChain(_token, amountLD, calls) {} catch {
            IERC20(_token).safeTransfer(user, amountLD);
            return;
        }
        // Use _nonce to calculate the diff amount of stable _token left from that trade and send it to user, prevent stack too deep
        _nonce = _getBalance(_token) + amountLD - contractStatus.balanceSrcBefore;
        if (_nonce > 0) {
            IERC20(_token).safeTransfer(user, _nonce);
        }

        if (dstToken == address(0)) {
            // trade to ETH
            contractStatus.balanceDstAfter = address(this).balance; // eth balance of contract
            _nonce = contractStatus.balanceDstAfter - contractStatus.balanceDstBefore;
            if (_nonce > 0) {
                payable(user).sendValue(_nonce);
            }
        } else {
            contractStatus.balanceDstAfter = IERC20(dstToken).balanceOf(address(this));
            _nonce = contractStatus.balanceDstAfter - contractStatus.balanceDstBefore;
            if (_nonce > 0) {
                IERC20(dstToken).safeTransfer(user, _nonce);
            }
        }
    }

    /**
     * @notice Executes a swap using the Thorchain router.
     * @param info Information about the swap, including the user, token addresses, amounts, and integrator details.
     * @param calls An array of SwapCall structs representing the swap execution steps.
     * @param permit Permit data for token transfer.
     * @param memo Additional information for the Thorchain deposit, contain UTXO address for receiving fund
     * @dev Validates the output amount and executes the swap logic.
     */
    function swapTC(
        SwapTC calldata info,
        SwapCall[] calldata calls,
        Permit calldata permit,
        string memory memo
    ) external payable override nonReentrant onlyRouter {
        require(info.amountOutMin > 0, "Unizen: Invalid-amount-Out-min"); // prevent mev attack
        uint256 amount = _obtainSrcTokenFromUser(info.user, info.srcToken, info.amountIn, 0, info.integrator, permit);
        if (msg.value > 0) {
            // deposit directly to ThorchainRouter
            require(info.srcToken == address(0), "Unizen: Invalid-native-amount");
            ITcRouter(tcRouter).depositWithExpiry{value: amount}(
                payable(info.vault),
                address(0),
                amount,
                memo,
                info.deadline
            );
            emit CrossChainUTXO(info.user, address(0), info.vault, info.amountIn, info.apiId);
            return;
        }
        // execute trade logic, swap from tokens to stable
        IERC20 dstToken = IERC20(info.dstToken);
        if (calls.length > 0) {
            uint256 balanceDstBefore = _getBalance(info.dstToken);
            _swap(info.srcToken, amount, calls, false);
            uint256 balanceDstAfter = _getBalance(info.dstToken);
            uint256 totalDstAmount = balanceDstAfter - balanceDstBefore;
            require(totalDstAmount >= info.amountOutMin, "Unizen: Slippage");
            dstToken.safeApprove(tcRouter, 0);
            dstToken.safeApprove(tcRouter, totalDstAmount);
            ITcRouter(tcRouter).depositWithExpiry(
                payable(info.vault),
                info.dstToken,
                totalDstAmount,
                memo,
                info.deadline
            );
            dstToken.safeApprove(tcRouter, 0);
            emit CrossChainUTXO(info.user, info.dstToken, info.vault, totalDstAmount, info.apiId);
        } else {
            // no swap, use stable
            require(info.srcToken == info.dstToken, "Unizen: Wrong-Token");
            dstToken.safeApprove(tcRouter, 0);
            dstToken.safeApprove(tcRouter, amount);
            ITcRouter(tcRouter).depositWithExpiry(payable(info.vault), info.dstToken, amount, memo, info.deadline);
            dstToken.safeApprove(tcRouter, 0);
            emit CrossChainUTXO(info.user, info.dstToken, info.vault, amount, info.apiId);
        }
    }
}
