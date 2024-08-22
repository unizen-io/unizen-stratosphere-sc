// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IUnizenDexAggr {
     struct SwapCall {
        address targetExchange;
        address sellToken;
        address buyToken;
        uint256 amount;
        bytes data; // Encoded data to execute the trade by contract call
    }  

    struct SwapTC { 
        address srcToken; //Input token
        address dstToken; //Output token, must be asset support by Thorchain like ETH, USDT ... 
        uint256 amountIn; // amount in user want to trade
        uint256 amountOutMin; // expected amount out min
        uint256 feePercent;
        uint256 sharePercent;
        address vault;
        uint256 deadline;
        string memo;
        string uuid;
        uint16 apiId;
    }

    struct SwapExactInInfo {
        address receiver; // Receiver address
        address srcToken; //Input token
        address dstToken; //Output token
        uint256 amountIn; // amount in user want to trade
        uint256 amountOutMin; // expected amount out min
        uint256 actualQuote; // expected amount out
        uint256 feePercent;
        uint256 sharePercent;
        uint16 apiId;
        uint16 userPSFee;
        string uuid; //integrator uuid (if swap directly by unizen leave it empty "")
    }

    struct SwapExactOutInfo {
        address receiver; // Receiver address
        address srcToken; //Input token
        address dstToken; //Output token
        uint256 amountOut; // expect amount out of user
        uint256 amountInMax; //amount in max that user willing to pay
        uint256 actualQuote; // expected amountIn,
        uint256 feePercent;
        uint256 sharePercent;
        uint16 apiId;
        uint16 userPSFee;
        string uuid; //integrator uuid (if swap directly by unizen leave it empty "")
    }

    struct CrossChainSwapSg {
        address srcToken;
        address receiver;
        uint256 amount;
        uint256 nativeFee; // fee to LZ
        address dstToken;
        uint256 actualQuote; // expected amount out
        uint256 gasDstChain;
        uint256 feePercent;
        uint256 sharePercent;
        uint16 dstChain; // dstChainId in LZ - not network chain id
        uint16 srcPool; // src stable pool id
        uint16 dstPool; // dst stable pool id
        uint16 apiId;
        uint16 userPSFee;
        bool isFromNative;
        string uuid; //integrator uuid (if swap directly by unizen leave it empty "")
    }
    struct ContractStatus {
        uint256 balanceDstBefore;
        uint256 balanceDstAfter;
        uint256 balanceSrcBefore;
        uint256 balanceSrcAfter;
        uint256 totalDstAmount;
    }

    event Swapped(
        uint256 amountIn,
        uint256 amountOut,
        address srcToken,
        address dstToken,
        address receiver,
        address sender,
        uint16 apiId
    );

    event CrossChainSwapped(
        uint16 chainId,
        address user,
        uint256 valueInUSD,
        uint16 apiId
    );

    event CrossChainUTXO(
        address srcToken,
        address vault,
        uint256 amount, 
        uint16 apiId
    );

    function getIntegratorInfor(
        string memory uuid
    ) external view returns (address, uint256, uint256);

    function psFee() external view returns (uint256);

    function integratorFees(string memory uuid) external view returns (uint256);

    function integratorAddrs(
        string memory uuid
    ) external view returns (address);

    function integratorUnizenSFP(
        string memory uuid
    ) external view returns (uint256);

    function psShare() external view returns (uint256);

    function uuidType(string memory uuid) external view returns (uint8);


    function initialize() external;
}