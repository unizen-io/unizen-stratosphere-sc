// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EthReceiver} from "../../helpers/EthReceiver.sol";
import {IGaslessExecutor} from "./interfaces/IGaslessExecutor.sol";
import {BaseExecutor} from "./BaseExecutor.sol";

/**
 * @title GasLessExecutor
 * @notice This contract enables gasless transactions by allowing users to submit orders that can be executed by a relayer.
 * @dev It validates orders using EIP-712 signatures and handles token transfers between users and DEXes.
 */
contract GasLessExecutor is BaseExecutor, IGaslessExecutor {
    using SafeERC20 for IERC20;
    using Address for address payable;

    bytes32 private constant DOMAIN_NAME = keccak256("GasLessExecutor");
    bytes32 private constant DOMAIN_VERSION = keccak256("1");
    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            abi.encodePacked("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        );
    bytes32 public constant UNIZEN_ORDER_TYPE_HASH =
        keccak256(
            abi.encodePacked(
                "UnizenGasLessOrder(address user,address receiver,address srcToken,address dstToken,uint256 amountIn,uint256 fee,uint256 amountOutMin,uint256 deadline,bytes32 tradeHash)"
            )
        );
    bytes32 private _CACHED_DOMAIN_SEPARATOR;
    uint256 private _CACHED_CHAIN_ID;

    /// @notice Mapping to track valid senders for gasless execution.
    mapping(address => bool) public isValidSender;
    mapping(address => mapping(bytes32 => bool)) isExecuted;

    /**
     * @notice Initializes the GasLessExecutor contract.
     * @param _router The address of the router contract.
     * @param _dexHelper The address of the DexHelper contract.
     */
    function initialize(address _router, address _dexHelper) external initializer {
        __GasLessExecutor_init(_router, _dexHelper);
    }

    /**
     * @dev Internal initialization function to set up the contract state.
     * @param _router The address of the router contract.
     * @param _dexHelper The address of the DexHelper contract.
     */
    function __GasLessExecutor_init(address _router, address _dexHelper) internal onlyInitializing {
        __BaseExecutor_init(_router, _dexHelper);
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME, DOMAIN_VERSION, block.chainid, address(this))
        );
    }

    /**
     * @notice Retrieves the current domain separator used for order signature validation.
     * @return The domain separator used in the encoding of order signatures.
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            block.chainid == _CACHED_CHAIN_ID
                ? _CACHED_DOMAIN_SEPARATOR
                : keccak256(
                    abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME, DOMAIN_VERSION, block.chainid, address(this))
                );
    }

    /**
     * @notice Sets the validity of a sender for gasless transactions.
     * @dev Only the contract owner can call this function.
     * @param sender The address of the sender to set validity for.
     * @param isValid A boolean indicating whether the sender is valid.
     */
    function setSender(address sender, bool isValid) external onlyOwner {
        isValidSender[sender] = isValid;
    }

    /**
     * @notice Computes the hash of a gasless order for signature validation.
     * @param order The gasless order to hash.
     * @return The hashed order used for signature verification.
     */
    function hashOrder(UnizenGasLessOrder calldata order) public view returns (bytes32) {
        bytes32 dataHash = keccak256(
            abi.encode(
                UNIZEN_ORDER_TYPE_HASH,
                order.user,
                order.receiver,
                order.srcToken,
                order.dstToken,
                order.amountIn,
                order.fee,
                order.amountOutMin,
                order.deadline,
                order.tradeHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
    }

    /**
     * @notice Extracts the r, s, and v values from a signature.
     * @param sig The signature to parse.
     * @return r The r value of the signature.
     * @return s The s value of the signature.
     * @return v The recovery id of the signature.
     */
    function getRsv(bytes memory sig) internal pure returns (bytes32, bytes32, uint8) {
        require(sig.length == 65, "Unizen: Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := and(mload(add(sig, 65)), 255)
        }
        if (v < 27) v += 27;
        require(
            uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "Unizen: Invalid sig value S"
        );
        require(v == 27 || v == 28, "Unizen: Invalid sig value V");
        return (r, s, v);
    }

    /**
     * @notice Validates a gasless order and its signature.
     * @param info The gasless order to validate.
     * @param signature The signature to verify.
     * @dev Throws if the signature is invalid or if the order has expired.
     */
    function _validOrder(UnizenGasLessOrder calldata info, bytes calldata signature) private view {
        require(info.deadline >= block.timestamp, "Unizen: Order-expired");
        bytes32 orderHash = hashOrder(info);
        (bytes32 r, bytes32 s, uint8 v) = getRsv(signature);
        address signer = ecrecover(orderHash, v, r, s);
        require(signer != address(0), "Unizen: Invalid-signer");
        if (signer != info.user) {
            revert("Unizen: Invalid-user-signature");
        }
    }

    /**
     * @notice Executes a gasless swap on behalf of the user.
     * @param info The details of the gasless order.
     * @param calls The swap calls to execute.
     * @param permit The permit data for token transfer.
     * @param orderSign The signature of the gasless order.
     * @dev Validates the tx sender(tx.origin), order, transfers tokens, and performs the swap, ensuring all conditions are met.
     */
    function swapGasLess(
        UnizenGasLessOrder calldata info,
        SwapCall[] calldata calls,
        Permit calldata permit,
        bytes calldata orderSign
    ) external onlyRouter nonReentrant {
        uint256 amount = info.amountIn;
        require(info.receiver != address(0), "Unizen: Invalid-receiver");
        require(!isExecuted[info.user][info.tradeHash], "Unizen: Order-executed");
        _validOrder(info, orderSign);
        _routerTransferTokens(permit, info.srcToken, info.user, info.amountIn);
        uint256 balanceDstBefore = _getBalance(info.dstToken);
        // execute trade logic
        amount = amount - info.fee;
        _swap(info.srcToken, amount, calls, false);
        uint256 balanceDstAfter = _getBalance(info.dstToken);
        uint256 totalDstAmount = balanceDstAfter - balanceDstBefore;
        require(totalDstAmount >= info.amountOutMin, "Unizen: Return-amount-is-not-enough");
        _transferTokenToUser(info.dstToken, info.receiver, totalDstAmount);
        // pay fee to tx sender
        IERC20(info.srcToken).safeTransfer(tx.origin, info.fee);
        isExecuted[info.user][info.tradeHash] = true;
        emit GasLessSwapped(info.user, info.srcToken, info.dstToken, info.amountIn, totalDstAmount);
    }
}
