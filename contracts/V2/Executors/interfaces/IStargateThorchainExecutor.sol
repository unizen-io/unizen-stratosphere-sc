import {Types} from "./Types.sol";

interface IStargateThorchainExecutor is Types {
    struct CrossChainSwapSg {
        address user;
        address srcToken;
        address receiver;
        uint256 amount;
        uint256 nativeFee; // fee to LZ
        address dstToken;
        uint256 gasDstChain;
        uint16 dstChain; // dstChainId in LZ - not network chain id
        uint16 srcPool; // src stable pool id
        uint16 dstPool; // dst stable pool id
        bool isFromNative;
        Integrator integrator;
        uint16 apiId;
    }

    struct SwapTC {
        address user;
        address srcToken; //Input token
        address dstToken; //Output token, must be asset support by Thorchain like ETH, USDT ...
        uint256 amountIn; // amount in user want to trade
        uint256 amountOutMin; // expected amount out min
        address vault;
        uint256 deadline;
        Integrator integrator;
        uint16 apiId;
    }

    /**
     * Stargate crosschain swap tx done on source chain
     * @param sender sender address
     * @param dstChainId destination chain id
     * @param tokenOut address of stable token on source chain
     * @param tokenOutValue amount of tokenOut
     * @param apiId integrator api id
     */
    event StargateCrossChainSwapped(
        address indexed sender,
        uint16 dstChainId,
        address tokenOut,
        uint256 tokenOutValue,
        uint16 apiId
    );

    event CrossChainUTXO(address indexed sender, address srcToken, address vault, uint256 amount, uint16 apiId);

    function swapTC(
        SwapTC memory info,
        SwapCall[] calldata calls,
        Permit calldata permit,
        string calldata memo
    ) external payable;

    function swapSTG(
        CrossChainSwapSg memory swapInfo,
        SwapCall[] calldata calls,
        SwapCall[] memory dstCalls,
        Permit calldata permit
    ) external payable;
}
