// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;
interface IUnizenDexAggrV3 {
    struct SwapCall {
        address targetExchange;
        address sellToken;
        address buyToken;
        uint256 amount;
        bytes data; // Encoded data to execute the trade by contract call
    }

    struct CrossChainSwapDb {
        address receiver; // address of receiver
        uint16 dstChain; // dstChainId
        uint16 apiId; // integrator api id
        uint64 dlnOrderSalt; // dln order salt
        address srcToken; // address of source token
        uint256 amount; // amount token in
        address srcTokenOut; // address of stable token on source chain
        uint256 srcTokenOutDecimals; // decimals of srcTokenOut
        uint256 minSrcTokenOutAmt; // expected amount of stable/ETH on source chain
        address dstTokenIn; // address of stable token on destination chain
        uint256 dstTokenInDecimals; // decimals of dstTokenIn
        uint256 nativeFee; // fee to DLN in native
        uint256 dlnProtocolFeeBps; // DLN Protocol fee Bps on src chain
        uint256 dlnTakerFeeBps; // DLN TakerMargin fee Bps on dst chain
        uint256 dlnOperatingExpense; // DLN EstimatedOperatingExpenses on dst chain
        bytes externalCall; // encoded data need by dlnAdapter on destination chain
        string uuid; //integrator uuid (if swap directly by unizen leave it empty "")
        uint256 feePercent;
        uint256 sharePercent;
    }

    struct CrossChainSwapMeson {
        address srcToken; // address of source token
        uint256 amount; // amount token in
        uint16 dstChain; // dstChainId
        address srcTokenOut; // address of stable token on source chain
        uint256 minSrcTokenOutAmt; // expected amount of stable/ETH on source chain
        uint256 encodedSwap; // Meson encoded swap
        uint200 postingValue; // Meson posting value
        address initiator; // address of initiator, which is supply by Meson for each swap
        uint16 apiId; // integrator api id
        string uuid; //integrator uuid (if swap directly by unizen leave it empty "")
        uint256 feePercent;
        uint256 sharePercent;
    }

    struct CrossChainSwapWormhole {
        address receiver; // address of receiver
        address srcToken; // address of source token
        uint256 amount; // amount token in
        uint256 minSrcTokenOutAmt; // expected amount of stable/ETH on source chain
        uint256 nativeFee; // fee to wormhole in native
        uint256 dstChainGasLimit; // gas limit for tx execution on destination chain
        uint16 wormholeDstChain; // Wormhole's chain id for destination chain
        address dstChainAggr; // receive contract on destination chain
        address dstToken; // address of destination token on destination chain
        uint256 minDstTokenAmt; // minimum of dstToken quote
        uint16 apiId; // integrator api id
        string uuid; // integrator uuid (if swap directly by unizen leave it empty "")
        uint256 feePercent;
        uint256 sharePercent;
    }

    /**
     * @notice debridge crosschain swap sucess on destination chain
     * @param orderId debridge order id
     * @param dstToken destination token address
     * @param amount destination token amount
     * @param receiver address of receiver
     */
    event DstChainSwapSuccess(bytes32 indexed orderId, address dstToken, uint256 amount, address indexed receiver);

    /**
     * @notice debridge crosschain swap failed on destination chain
     * @param orderId debridge order id
     * @param stableToken stable token address
     * @param amount stable token amount
     * @param receiver address of receiver
     */
    event DstChainSwapFailed(bytes32 indexed orderId, address stableToken, uint256 amount, address indexed receiver);

    /**
     * Debridge crosschain swap tx done on source chain
     * @param sender sender address
     * @param dstChainId destination chain id
     * @param tokenOut address of stable token on source chain
     * @param tokenOutValue amount of tokenOut
     * @param apiId integrator api id
     */
    event DebridgeCrossChainSwapped(
        address indexed sender,
        uint16 dstChainId,
        address tokenOut,
        uint256 tokenOutValue,
        uint16 apiId
    );

    /**
     * Meson crosschain swap tx done on source chain
     * @param sender sender address
     * @param dstChainId destination chain id
     * @param tokenOut address of stable token on source chain
     * @param tokenOutValue amount of tokenOut
     * @param apiId integrator api id
     */
    event MesonCrossChainSwapped(
        address indexed sender,
        uint16 dstChainId,
        address tokenOut,
        uint256 tokenOutValue,
        uint16 apiId
    );

    /**
     * @notice wormhole crosschain swap sucess on destination chain
     * @param dstToken destination token address
     * @param amount destination token amount
     * @param receiver address of receiver
     */
    event WormholeDstChainSwapSuccess(address dstToken, uint256 amount, address indexed receiver);

    /**
     * @notice wormhole crosschain swap failed  on destination chain
     * @param stableToken stable token address
     * @param amount stable token amount
     * @param receiver address of receiver
     */
    event WormholeDstChainSwapFailed(address stableToken, uint256 amount, address indexed receiver);

    /**
     * Wormhole crosschain swap tx done on source chain
     * @param sender sender address
     * @param wormholeDstChainId destination chain id - in Wormhole system
     * @param tokenOut address of stable token on source chain
     * @param tokenOutValue amount of tokenOut
     * @param apiId integrator api id
     */
    event WormholeCrossChainSwapped(
        address indexed sender,
        uint16 wormholeDstChainId,
        address tokenOut,
        uint256 tokenOutValue,
        uint16 apiId
    );
}
