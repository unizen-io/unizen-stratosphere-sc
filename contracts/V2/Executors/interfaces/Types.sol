pragma solidity >=0.8.0;

interface Types {
    struct Integrator {
        address feeReceiver;
        uint256 feePercent;
        uint256 sharePercent;
    }

    struct SwapCall {
        address targetExchange;
        address sellToken;
        address buyToken;
        uint256 amount;
        bytes data; // Encoded data to execute the trade by contract call
    }

    struct ContractBalance {
        uint256 balanceDstBefore;
        uint256 balanceDstAfter;
        uint256 balanceSrcBefore;
        uint256 balanceSrcAfter;
        uint256 totalDstAmount;
    }

    struct Permit {
        address user;
        uint256 amount;
        uint256 deadline;
        uint256 nonce;
        bytes sign;
    }
}
