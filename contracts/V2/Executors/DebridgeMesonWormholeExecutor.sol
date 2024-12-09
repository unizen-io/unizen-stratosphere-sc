// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {EthReceiver} from "../../helpers/EthReceiver.sol";
import {IDebridgeMesonWormholeExecutor} from "./interfaces/IDebridgeMesonWormholeExecutor.sol";
import "../../interfaces/IDlnSource.sol";
import "../../interfaces/IMeson.sol";
import "../../libraries/wormhole/CCTPBase.sol";
import {BaseExecutor} from "./BaseExecutor.sol";

contract DebridgeMesonWormholeExecutor is IDebridgeMesonWormholeExecutor, BaseExecutor, CCTPSender, CCTPReceiver {
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant BPS_DENOMINATOR = 10000;

    // DLN config
    IDlnSource public dlnSource;
    address public dlnAdapter;
    mapping(address => bool) public isDlnStable;

    // Meson config
    IMeson public meson;
    address private _mesonCurrentAuthorizer;
    mapping(address => bool) public isMesonStable;

    /// @notice Ensures that only the DLN adapter can call the modified function
    modifier onlyDlnAdaptor() {
        require(msg.sender == dlnAdapter, "Unizen: Only-Dln-Contract");
        _;
    }

    /**
     * @notice Initializes the contract with DLN, Meson, and related configurations
     * @param _dlnSource The DLN source contract address
     * @param _dlnAdapter The DLN adapter address
     * @param _meson The Meson contract address
     * @param _router The router address
     * @param _dexHelper The dex helper contract address
     */
    function initialize(
        IDlnSource _dlnSource,
        address _dlnAdapter,
        IMeson _meson,
        address _router,
        address _dexHelper
    ) public initializer {
        __DebridgeMesonWormholeExecutor_init(_router, _dexHelper);
        dlnSource = _dlnSource;
        dlnAdapter = _dlnAdapter;
        meson = _meson;
        _mesonCurrentAuthorizer = address(0);
    }

    /**
     * @notice Internal function to initialize base executor
     * @param _router The router address
     * @param _dexHelper The dex helper contract address
     */
    function __DebridgeMesonWormholeExecutor_init(address _router, address _dexHelper) internal onlyInitializing {
        __BaseExecutor_init(_router, _dexHelper);
    }

    /**
     * @notice Sets the DLN source and adapter addresses
     * @param _dlnSource The DLN source contract address
     * @param _dlnAdapter The DLN adapter address
     */
    function setDLNConfigution(IDlnSource _dlnSource, address _dlnAdapter) external onlyOwner {
        dlnSource = _dlnSource;
        dlnAdapter = _dlnAdapter;
    }

    /**
     * @notice Updates DLN stable token statuses
     * @param stableTokens An array of stable token addresses
     * @param isActive An array of booleans indicating whether each token is active
     */
    function setDlnStable(address[] calldata stableTokens, bool[] calldata isActive) external onlyOwner {
        for (uint8 i = 0; i < stableTokens.length; i++) {
            isDlnStable[stableTokens[i]] = isActive[i];
        }
    }

    /**
     * @notice Sets the Meson contract address
     * @param _meson The Meson contract address
     */
    function setMesonConfigution(IMeson _meson) external onlyOwner {
        meson = _meson;
    }

    /**
     * @notice Updates Meson stable token statuses
     * @param stableTokens An array of stable token addresses
     * @param isActive An array of booleans indicating whether each token is active
     */
    function setMesonStable(address[] calldata stableTokens, bool[] calldata isActive) external onlyOwner {
        for (uint8 i = 0; i < stableTokens.length; i++) {
            isMesonStable[stableTokens[i]] = isActive[i];
        }
    }

    /**
     * @notice Configures the Wormhole-related settings
     * @param _wormholeRelayer The Wormhole relayer address
     * @param _wormhole The Wormhole contract address
     * @param _circleMessageTransmitter The Circle message transmitter address
     * @param _circleTokenMessenger The Circle token messenger address
     * @param _WormholeUSDC The Wormhole USDC token address
     */
    function setWormholeConfig(
        address _wormholeRelayer,
        address _wormhole,
        address _circleMessageTransmitter,
        address _circleTokenMessenger,
        address _WormholeUSDC
    ) external onlyOwner {
        _setWormholeBaseConfig(
            _wormholeRelayer,
            _wormhole,
            _circleMessageTransmitter,
            _circleTokenMessenger,
            _WormholeUSDC
        );

        setCCTPDomain(2, 0);
        setCCTPDomain(5, 7);
        setCCTPDomain(6, 1);
        setCCTPDomain(24, 2);
        setCCTPDomain(23, 3);
        setCCTPDomain(30, 6);
    }

    /**
     * @notice Executes a cross-chain swap using the Debridge protocol
     * @param info The cross-chain swap information
     * @param externalCall External dex call data on destination chain
     * @param calls An array of dex trade calls
     * @param permit The token permit struct for token approvals
     */
    function swapDB(
        CrossChainSwapDb calldata info,
        bytes calldata externalCall,
        SwapCall[] calldata calls,
        Permit calldata permit
    ) external payable override nonReentrant onlyRouter {
        require(isDlnStable[info.srcTokenOut], "Unizen: Invalid-token-out");

        uint256 srcTokenAmt = _obtainSrcTokenFromUser(
            info.user,
            info.srcToken,
            info.amount,
            info.nativeFee,
            info.integrator,
            permit
        );

        uint256 gotTokenOutAmt = _executeSrcTrade(
            info.srcToken,
            srcTokenAmt,
            info.srcTokenOut,
            info.minSrcTokenOutAmt,
            calls
        );

        /* ======================================================
        Send crosschain swap order
        ====================================================== */
        uint256 takeTokenAmt = _calculateTakeAmount(
            gotTokenOutAmt,
            info.srcTokenOut == address(0),
            info.srcTokenOutDecimals,
            info.dstTokenInDecimals,
            info.dlnProtocolFeeBps,
            info.dlnTakerFeeBps,
            info.dlnOperatingExpense
        );

        uint256 nativeValue = info.nativeFee;
        if (info.srcTokenOut == address(0)) {
            nativeValue += gotTokenOutAmt;
        } else {
            IERC20(info.srcTokenOut).safeApprove(address(dlnSource), 0);
            IERC20(info.srcTokenOut).safeApprove(address(dlnSource), gotTokenOutAmt);
        }

        dlnSource.createSaltedOrder{value: nativeValue}(
            DlnOrderLib.OrderCreation({
                giveTokenAddress: info.srcTokenOut,
                giveAmount: gotTokenOutAmt,
                takeTokenAddress: abi.encodePacked(info.dstTokenIn),
                takeAmount: takeTokenAmt,
                takeChainId: info.dstChain,
                receiverDst: abi.encodePacked(info.receiver),
                givePatchAuthoritySrc: info.user,
                orderAuthorityAddressDst: abi.encodePacked(info.user),
                allowedTakerDst: "", // empty => anyone on dst chain can fulfill the order
                externalCall: externalCall,
                allowedCancelBeneficiarySrc: "" // empty => sender will be account receiving token back on cancel
            }),
            info.dlnOrderSalt,
            "", // _affiliateFee
            7370, // _referralCode
            "", // _permitEnvelope
            "" // _metadata
        );

        emit DebridgeCrossChainSwapped(info.user, info.dstChain, info.srcTokenOut, gotTokenOutAmt, info.apiId);
    }

    /**
     * @notice Calculates the amount of tokens to be received on the destination chain
     * @param giveAmount The amount of tokens to give
     * @param useNativeCrossChain Whether native tokens are being used for cross-chain transfer
     * @param srcTokenOutDecimals The decimals of the source token
     * @param dstTokenInDecimals The decimals of the destination token
     * @param dlnProtocolFeeBps The protocol fee in basis points
     * @param dlnTakerFeeBps The taker fee in basis points
     * @param operatingFee The estimated operating expenses on the destination chain
     * @return takeAmt The final amount of tokens to be received on the destination chain
     */
    function _calculateTakeAmount(
        uint256 giveAmount,
        bool useNativeCrossChain,
        uint256 srcTokenOutDecimals,
        uint256 dstTokenInDecimals,
        uint256 dlnProtocolFeeBps,
        uint256 dlnTakerFeeBps,
        uint256 operatingFee
    ) internal pure returns (uint256 takeAmt) {
        // src chain: minus DlnProtocolFee 0.04%
        if (dlnProtocolFeeBps > 0) {
            takeAmt = (giveAmount * (BPS_DENOMINATOR - dlnProtocolFeeBps)) / BPS_DENOMINATOR;
        }

        // cross chain: change token decimals when move from src chain to dst chain
        if (!useNativeCrossChain && srcTokenOutDecimals != dstTokenInDecimals) {
            if (dstTokenInDecimals > srcTokenOutDecimals) {
                takeAmt = takeAmt * 10 ** (dstTokenInDecimals - srcTokenOutDecimals);
            } else {
                takeAmt = takeAmt / 10 ** (srcTokenOutDecimals - dstTokenInDecimals);
            }
        }

        // dst chain: minus TakerMargin 0.04%
        if (dlnTakerFeeBps > 0) {
            takeAmt = (takeAmt * (BPS_DENOMINATOR - dlnTakerFeeBps)) / BPS_DENOMINATOR;
        }

        // dst chain: minus EstimatedOperatingExpenses
        takeAmt -= operatingFee;
    }

    /**
     * @notice Handles the receipt of ERC20 tokens, validates and executes a function call.
     * @dev Only callable by the adapter. This function decodes the payload to extract execution data.
     *      If the function specified in the callData is prohibited, or the recipient contract is zero,
     *      all received tokens are transferred to the fallback address.
     *      Otherwise, it attempts to execute the function call. Any remaining tokens are then transferred to the fallback address.
     * @param _orderId The ID of the order that triggered this function.
     * @param _stableToken The stable token received from DlnExternalCallAdaptor
     * @param _stableAmount The amount of tokens transferred.
     * @param _receiver The address user to receive tokenOut.
     * @param _payload The encoded data containing the execution data
     *          - tokenOut: token that user want to receive
     *          - calls: swap calls to exchange _token for tokenOut
     * @return callSucceeded A boolean indicating whether the call was successful.
     * @return callResult The data returned from the call.
     */
    function onERC20Received(
        bytes32 _orderId,
        address _stableToken,
        uint256 _stableAmount,
        address _receiver,
        bytes memory _payload
    ) external onlyDlnAdaptor returns (bool callSucceeded, bytes memory callResult) {
        require(_receiver != address(0), "Unizen: Invalid-receiver");

        (address tokenOut, SwapCall[] memory calls) = abi.decode(_payload, (address, SwapCall[]));

        try
            this.handleDstChainSwap{gas: gasleft() - 35000}(_receiver, _stableToken, tokenOut, _stableAmount, calls)
        returns (uint256 tokenOutAmt) {
            emit DebridgeDstChainSwapSuccess(_orderId, tokenOut, tokenOutAmt, _receiver);
        } catch {
            IERC20(_stableToken).safeTransfer(_receiver, _stableAmount);
            emit DebridgeDstChainSwapFailed(_orderId, _stableToken, _stableAmount, _receiver);
        }
        callSucceeded = true;
    }

    /**
     * @dev function to swap cross-chain via Meson
     * @param info swapInfo
     * @param calls dex trade external call
     */
    function swapMeson(
        CrossChainSwapMeson calldata info,
        SwapCall[] calldata calls,
        Permit calldata permit
    ) external payable override nonReentrant onlyRouter {
        require(isMesonStable[info.srcTokenOut], "Unizen: Invalid-token-out");

        uint256 srcTokenAmt = _obtainSrcTokenFromUser(
            info.user,
            info.srcToken,
            info.amount,
            0,
            info.integrator,
            permit
        );

        uint256 gotTokenOutAmt = _executeSrcTrade(
            info.srcToken,
            srcTokenAmt,
            info.srcTokenOut,
            info.minSrcTokenOutAmt,
            calls
        );
        // In Meson, stable token is precalulated, so we need to send back residual srcToken
        uint256 residual = gotTokenOutAmt - info.minSrcTokenOutAmt;
        if (residual > 0) {
            _transferTokenToUser(info.srcTokenOut, info.user, residual);
        }

        /* ======================================================
        Send crosschain swap order
        ====================================================== */
        _mesonCurrentAuthorizer = info.initiator;
        if (info.srcTokenOut == address(0)) {
            meson.postSwapFromContract{value: info.minSrcTokenOutAmt}(
                info.encodedSwap,
                info.postingValue,
                address(this)
            );
        } else {
            IERC20 srcTokenOutContract = IERC20(info.srcTokenOut);
            srcTokenOutContract.safeApprove(address(meson), 0);
            srcTokenOutContract.safeApprove(address(meson), info.minSrcTokenOutAmt);
            meson.postSwapFromContract(info.encodedSwap, info.postingValue, address(this));
        }
        _mesonCurrentAuthorizer = address(0);

        emit MesonCrossChainSwapped(info.user, info.dstChain, info.srcTokenOut, info.minSrcTokenOutAmt, info.apiId);
    }

    /**
     * @notice Performs a cross-chain token swap using Wormhole.
     * @dev This function facilitates the cross-chain swap by obtaining the source token, executing the source chain swap,
     * and sending the payload containing the destination chain swap data through Wormhole.
     * It verifies that the destination chain aggregator is registered before executing the swap.
     * @param info Struct containing information about the cross-chain swap, including user, tokens, amounts, and destination chain details.
     * @param calls An array of SwapCall structs representing the swap calls to be executed on the source chain.
     * @param dstCalls An array of SwapCall structs representing the swap calls to be executed on the destination chain.
     * @param permit Permit data allowing token transfers on behalf of the user.
     */
    function swapWormhole(
        CrossChainSwapWormhole calldata info,
        SwapCall[] calldata calls,
        SwapCall[] calldata dstCalls,
        Permit calldata permit
    ) external payable override nonReentrant onlyRouter {
        if (registeredSenders[info.wormholeDstChain] != _addressToBytes32CCTP(info.dstChainAggr)) {
            revert NotRegisteredContract();
        }

        uint256 srcTokenAmt = _obtainSrcTokenFromUser(
            info.user,
            info.srcToken,
            info.amount,
            info.nativeFee,
            info.integrator,
            permit
        );

        uint256 gotTokenOutAmt = _executeSrcTrade(
            info.srcToken,
            srcTokenAmt,
            WormholeUSDC,
            info.minSrcTokenOutAmt,
            calls
        );

        /* ======================================================
        Send crosschain swap order
        ====================================================== */
        bytes memory payload = abi.encode(info.receiver, info.dstToken, dstCalls);
        bytes memory relayerPayload = abi.encode(gotTokenOutAmt, payload);

        _sendUSDCWithPayloadToEvm(
            info.wormholeDstChain,
            info.dstChainAggr,
            relayerPayload,
            info.dstChainGasLimit,
            info.nativeFee,
            gotTokenOutAmt
        );

        emit WormholeCrossChainSwapped(info.user, info.wormholeDstChain, WormholeUSDC, gotTokenOutAmt, info.apiId);
    }

    /**
     * @notice Debridge destination chain handler function.
     * @param _payload arbitrary crosschain data
     * @param _stableAmount amount of USDC received
     * @param _srcAddress address of sender contract on source chain - in bytes32 format
     * @param _srcChain source chain Wormhole's id
     */
    function _onWormholeUsdcReceived(
        bytes memory _payload,
        uint256 _stableAmount,
        bytes32 _srcAddress,
        uint16 _srcChain,
        bytes32 // deliveryHash
    ) internal override onlyWormholeRelayer {
        if (registeredSenders[_srcChain] != _srcAddress) {
            revert NotRegisteredContract();
        }

        (address receiver, address tokenOut, SwapCall[] memory calls) = abi.decode(
            _payload,
            (address, address, SwapCall[])
        );

        require(receiver != address(0), "Unizen: Invalid-receiver");

        try
            this.handleDstChainSwap{gas: gasleft() - 35000}(receiver, WormholeUSDC, tokenOut, _stableAmount, calls)
        returns (uint256 tokenOutAmt) {
            emit WormholeDstChainSwapSuccess(tokenOut, tokenOutAmt, receiver);
        } catch {
            IERC20(WormholeUSDC).safeTransfer(receiver, _stableAmount);
            emit WormholeDstChainSwapFailed(WormholeUSDC, _stableAmount, receiver);
        }
    }

    /**
     * @notice Executes a trade on the source chain.
     * @dev This function performs the trade on the source chain by executing a series of swap calls.
     * If no swap calls are provided, it ensures the source token matches the expected output token and amount.
     * It also checks that the output token amount is greater than or equal to the minimum required amount.
     * @param srcToken The address of the source token being swapped.
     * @param srcTokenAmt The amount of the source token to swap.
     * @param srcTokenOut The address of the token expected after the swap.
     * @param minSrcTokenOutAmt The minimum amount of the output token expected after the swap.
     * @param calls An array of SwapCall structs representing the sequence of swaps to be executed.
     * @return gotTokenOutAmt The amount of the output token obtained after the swap.
     */
    function _executeSrcTrade(
        address srcToken,
        uint256 srcTokenAmt,
        address srcTokenOut,
        uint256 minSrcTokenOutAmt,
        SwapCall[] calldata calls
    ) internal returns (uint256 gotTokenOutAmt) {
        // Check if there are any swap calls to execute
        if (calls.length > 0) {
            // Record the balance of the output token before the swap
            uint256 balanceDstBefore = _getBalance(srcTokenOut);
            // Execute the swap calls
            _swap(srcToken, srcTokenAmt, calls, false);
            // Calculate the amount of output token obtained after the swap
            gotTokenOutAmt = _getBalance(srcTokenOut) - balanceDstBefore;
            // Ensure the obtained output token amount meets the minimum requirement
            require(gotTokenOutAmt >= minSrcTokenOutAmt, "Unizen: Not-enough-amount-out");
        } else {
            // If no swap calls, ensure source token and amount match the output token and required amount
            require(srcToken == srcTokenOut && srcTokenAmt == minSrcTokenOutAmt, "Unizen: Miss-match-token-out");
            return srcTokenAmt;
        }
    }

    /**
     * @notice Handles the token swap on the destination chain and transfers the tokens to the user.
     * @dev This function performs the swap on the destination chain using the provided swap calls. It then transfers the
     * resulting output tokens to the user and any remaining input tokens back to the user if the full amount is not swapped.
     * @param receiver The address of the user receiving the swapped tokens.
     * @param tokenIn The address of the token being swapped on the destination chain.
     * @param tokenOut The address of the token expected after the swap.
     * @param amountIn The amount of the input token being swapped.
     * @param calls An array of SwapCall structs representing the sequence of swaps to be executed on the destination chain.
     * @return tokenOutAmt The amount of the output token obtained after the swap.
     */
    function handleDstChainSwap(
        address receiver,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        SwapCall[] calldata calls
    ) external returns (uint256 tokenOutAmt) {
        // Ensure this function can only be called by the contract itself
        require(msg.sender == address(this), "Unizen: Not-unizen");

        // Record the balances of the input and output tokens before the swap
        uint256 tokenInBalanceBefore = _getBalance(tokenIn);
        uint256 tokenOutBalanceBefore = _getBalance(tokenOut);

        // Execute the swap calls
        _swap(tokenIn, amountIn, calls, true);

        // Calculate the amount of output token obtained after the swap
        tokenOutAmt = _getBalance(tokenOut) - tokenOutBalanceBefore;
        // Transfer the obtained output tokens to the user
        _transferTokenToUser(tokenOut, receiver, tokenOutAmt);

        // Calculate the amount of input token that was swapped
        uint256 amountInSwapped = tokenInBalanceBefore - _getBalance(tokenIn);
        // Transfer any remaining input tokens that were not swapped back to the user
        _transferTokenToUser(tokenIn, receiver, amountIn - amountInSwapped);
    }
}
