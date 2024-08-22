// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;
interface IUnizenTradeV2 {
    struct SwapCall {
        address targetExchange;
        uint256 amount;
        bytes data; // Encoded data to execute the trade by contract call
    }

    struct CrossChainSwapClr {
        uint16 srcChain;
        uint16 dstChain;
        uint32 slippage;
        bool isFromNative;
        address srcToken;
        address dstToken;
        address intermediary;
        uint256 amount; // trade amount of srcToken
        uint256 busFee; // fee to LZ
        uint256 executorFee;
        uint256 actualQuote; // expected amount
        string uuid; //integrator uuid (if swap directly by unizen leave it empty "")
        uint16 apiId;
    }

    struct ContractStatus {
        uint256 balanceSrcBefore;
        uint256 balanceSrcAfter;
        uint256 balanceDstBefore;
        uint256 balanceDstAfter;
        uint64 userNonce;
        uint256 bridgeAmount;
    }

    struct ContractStatusDstCLR {
        uint256 balanceStableBefore;
        uint256 balanceDstBefore;
        uint256 balanceDstAfter;
    }

    struct CrossChainSwapAxelar {
        uint16 dstChain;
        bool isFromNative;
        address srcToken;
        address dstToken;
        uint256 amount; // trade amount of srcToken
        uint256 gas; // fee to axlGas
        uint256 actualQuote;
        string dstChainName;
        string assetSymbol;
        string uuid;
        uint16 apiId;
    }

    event CrossChainCelerSwapped(uint16 chainId, address user, uint256 valueInUSD, uint16 apiId);
    event CrossChainAxelar(uint256 chainId, address user, uint256 valueInUSD, uint16 apiId);
    event CrossChainAxelarSwapped(string sourceChain, address user, uint256 valueInUSD, uint16 apiId);
}
