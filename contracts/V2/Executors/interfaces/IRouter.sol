import {Types} from "./Types.sol";

pragma solidity >=0.8.0;

interface IBaseExecutor {
    function unizenWithdrawEarnedFee(address payable receiver, address[] calldata tokens) external;
}

interface IRouter is Types {
    struct Executable {
        address executor;
        bytes4 selector;
        bytes data;
    }

    function routerTransferTokens(address token, address user, uint256 amount) external;

    function routerTransferTokensPermit2(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address user,
        bytes calldata signature
    ) external;

    function execute(Executable calldata program) external payable;
}
