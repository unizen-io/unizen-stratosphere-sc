import {Types} from "./Types.sol";

pragma solidity >=0.8.0;

interface ISingleChainExecutor is Types {
    struct SwapExactInInfo {
        address user;
        address receiver; // Receiver address
        address srcToken; //Input token
        address dstToken; //Output token
        uint256 amountIn; // amount in user want to trade
        uint256 amountOutMin; // expected amount out min
        Integrator integrator;
        uint16 apiId;
    }

    struct SwapExactOutInfo {
        address user;
        address receiver; // Receiver address
        address srcToken; //Input token
        address dstToken; //Output token
        uint256 amountOut; // expect amount out of user
        uint256 amountInMax; //amount in max that user willing to pay
        Integrator integrator;
        uint16 apiId;
    }

    event Swapped(
        address indexed user,
        uint256 amountIn,
        uint256 amountOut,
        address srcToken,
        address dstToken,
        uint16 apiId
    );

    function swap(SwapExactInInfo calldata info, SwapCall[] calldata calls, Permit calldata permit) external payable;

    function swapExactOut(
        SwapExactOutInfo calldata info,
        SwapCall[] calldata calls,
        Permit calldata permit
    ) external payable;
}
