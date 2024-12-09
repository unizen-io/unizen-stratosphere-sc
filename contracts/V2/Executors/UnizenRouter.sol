// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Controller} from "./Controller.sol";
import {EthReceiver} from "../../helpers/EthReceiver.sol";
import {IPermit2, ISignatureTransfer} from "../../../lib/permit2/src/interfaces/IPermit2.sol";
import {IRouter, IBaseExecutor} from "./interfaces/IRouter.sol";
import {IGaslessExecutor} from "./interfaces/IGaslessExecutor.sol";

/**
 * @title UnizenRouter
 * @notice This contract serves as a router for executing transactions through various executors.
 * @dev It implements the IRouter, Controller, EthReceiver, and ReentrancyGuardUpgradeable interfaces.
 */
contract UnizenRouter is IRouter, Controller, EthReceiver, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    IPermit2 public PERMIT2; // The Permit2 contract for gasless token transfers.

    mapping(address => bool) public isExecutor; // Mapping of valid executors.
    mapping(address => bool) public isGaslessExecutor; // Mapping of gasless executors.

    /**
     * @notice Initializes the UnizenRouter contract.
     * @dev This function is called only once to set up the contract state.
     */
    function initialize() external initializer {
        __UnizenDexAggr_init();
    }

    /**
     * @dev Internal initialization function to set up the contract.
     * It initializes the Controller and ReentrancyGuard contracts.
     */
    function __UnizenDexAggr_init() internal onlyInitializing {
        __Controller_init_();
        __ReentrancyGuard_init();
    }

    /**
     * @notice Sets the validity of an executor and gasless executor.
     * @param _executor The address of the executor.
     * @param isValid A boolean indicating if the executor is valid.
     * @param _isGaslessExecutor A boolean indicating if the executor is gasless.
     * @dev Can only be called by the contract owner.
     */
    function setExecutor(address _executor, bool isValid, bool _isGaslessExecutor) external onlyOwner {
        isExecutor[_executor] = isValid;
        isGaslessExecutor[_executor] = _isGaslessExecutor;
    }

    /**
     * @notice Sets the Permit2 contract address.
     * @param _permit2 The address of the Permit2 contract.
     * @dev Can only be called by the contract owner.
     */
    function setPermit2(address _permit2) external onlyOwner {
        PERMIT2 = IPermit2(_permit2);
    }

    /**
     * @notice Withdraws fees from executors.
     * @param executors An array of executor addresses.
     * @param tokens An array of token addresses to withdraw.
     * @param feeReceiver The address where the fees will be sent.
     * @dev Can only be called by the contract owner.
     */
    function unizenWithdrawFee(
        address[] calldata executors,
        address[] calldata tokens,
        address feeReceiver
    ) external onlyOwner {
        for (uint256 i; i < executors.length; i++) {
            IBaseExecutor(executors[i]).unizenWithdrawEarnedFee(payable(feeReceiver), tokens);
        }
    }

    /**
     * @notice Executes a program through an executor.
     * @param program The executable program containing the executor and function details.
     * @dev Validates the executor and the user calling the function, then runs the execution.
     */
    function execute(Executable calldata program) external payable override whenNotPaused {
        require(isExecutor[program.executor], "UnizenRouter: Invalid-executor");
        require(program.selector != hex"a8fb9368", "UnizenRouter: Invalid-selector");
        address user = abi.decode(program.data[:32], (address));
        if (!isGaslessExecutor[program.executor]) {
            require(user == _msgSender(), "UnizenRouter: Invalid-user");
        } else {
            require(IGaslessExecutor(program.executor).isValidSender(msg.sender), "Unizen-Router: Invalid-sender");
        }
        _runExecution(program, msg.value);
    }

    /**
     * @notice Runs the execution of a program by calling the executor.
     * @param program The executable program to run.
     * @param value The value of Ether sent with the call.
     * @dev This function is private and handles the low-level call to the executor.
     */
    function _runExecution(Executable calldata program, uint256 value) private {
        (bool result, bytes memory data) = program.executor.call{value: value}(
            abi.encodePacked(program.selector, program.data)
        );
        if (!result) {
            if (data.length >= 68) {
                assembly {
                    data := add(data, 0x04)
                }
                string memory reason = abi.decode(data, (string));
                revert(reason);
            } else {
                revert("UnizenRouter: execution revert with no reason");
            }
        }
    }

    /**
     * @notice Transfers tokens from a user to the executor.
     * @param token The address of the token to transfer.
     * @param user The address of the user from whom tokens will be transferred.
     * @param amount The amount of tokens to transfer.
     * @dev Can only be called by an executor and is non-reentrant.
     */
    function routerTransferTokens(
        address token,
        address user,
        uint256 amount
    ) external override whenNotPaused nonReentrant {
        require(isExecutor[msg.sender], "UnizenRouter: Invalid-executor");
        IERC20 _token = IERC20(token);
        _token.safeTransferFrom(user, msg.sender, amount);
    }

    /**
     * @notice Transfers tokens using Permit2 for gasless execution.
     * @param token The address of the token to transfer.
     * @param amount The amount of tokens to transfer.
     * @param nonce The nonce for the permit.
     * @param deadline The deadline for the permit.
     * @param user The address of the user from whom tokens will be transferred.
     * @param signature The signature of the permit.
     * @dev Can only be called by an executor and is non-reentrant.
     */
    function routerTransferTokensPermit2(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address user,
        bytes calldata signature
    ) external override whenNotPaused nonReentrant {
        require(isExecutor[msg.sender], "UnizenRouter: Invalid-executor");
        PERMIT2.permitTransferFrom(
            // The permit message. Spender will be inferred as the caller (us).
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
                nonce: nonce,
                deadline: deadline
            }),
            // The transfer recipient and amount.
            ISignatureTransfer.SignatureTransferDetails({to: msg.sender, requestedAmount: amount}),
            // The owner of the tokens, which must also be
            // the signer of the message, otherwise this call
            // will fail.
            user,
            // The packed signature that was the result of signing
            // the EIP712 hash of `permit`.
            signature
        );
    }
}
