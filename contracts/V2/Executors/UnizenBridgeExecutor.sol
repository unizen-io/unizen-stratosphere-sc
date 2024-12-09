// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {ISatBridge} from "./interfaces/ISatBridge.sol";
import "./lzApp/NonblockingLzAppUpgradeable.sol";

contract UnizenBridgeExecutor is ReentrancyGuardUpgradeable, NonblockingLzAppUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public fee;
    address public satBridge;
    address public unizenRouter;
    address public feeReceiver;
    mapping(address => bool) public _isValidToken;
    mapping(address => mapping(uint256 => address)) public srcToDstToken;

    modifier validToken(address token) {
        require(_isValidToken[token], "Unizen: Invalid-token");
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == unizenRouter, "Unizen: Invalid-router");
        _;
    }

    function initialize(address _router, address _satBridge, address _lzEndpoint) public virtual initializer {
        __UnizenBridgeExecutor_init(_router, _satBridge);
        __NonblockingLzAppUpgradeable_init(_lzEndpoint);
    }

    function __UnizenBridgeExecutor_init(address _router, address _satBridge) internal onlyInitializing {
        __ReentrancyGuard_init();
        unizenRouter = _router;
        satBridge = _satBridge;
    }

    function setRouter(address _unizenRouter) external onlyOwner {
        unizenRouter = _unizenRouter;
    }

    function setSatBridge(address _satBridge) external onlyOwner {
        satBridge = _satBridge;
    }

    function addToken(address token) external onlyOwner {
        _isValidToken[token] = true;
    }

    function removeToken(address token) external onlyOwner {
        _isValidToken[token] = false;
    }

    function setFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    function setDstToken(address srcToken, address dstToken, uint256 chainId) external onlyOwner {
        srcToDstToken[srcToken][chainId] = dstToken;
    }

    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
    }

    function _takeFee(IERC20 token, uint256 amount) internal returns (uint256 feeAmount) {
        require(feeReceiver != address(0), "Unizen: Invalid-fee-receiver");
        feeAmount = (amount * fee) / 10000;
        token.safeTransfer(feeReceiver, feeAmount);
    }

    function deposit(
        address user,
        uint256 destChainId,
        uint16 lzDstChainId,
        address token,
        uint256 amount,
        bytes calldata adapterParams
    ) external payable validToken(token) onlyRouter nonReentrant {
        require(destChainId != block.chainid, "Unizen: Invalid-chain-id");
        require(srcToDstToken[token][destChainId] != address(0), "Unizen: Not-support-yet");
        // transfer amount from user to this contract
        IRouter(unizenRouter).routerTransferTokens(token, user, amount);
        IERC20 bridgeToken = IERC20(token);
        // transfer fee to fee receiver
        if (fee > 0) {
            amount = amount - _takeFee(bridgeToken, amount);
        }
        bridgeToken.safeTransfer(satBridge, amount);
        // user param in lock function just for logging event at SatBridge contract
        ISatBridge(satBridge).lock(token, user, destChainId, amount);

        bytes memory payload = abi.encode(user, amount, srcToDstToken[token][destChainId]);
        _lzSend(lzDstChainId, payload, payable(user), address(0), adapterParams, msg.value);
    }

    // receive the bytes payload from the source chain via LayerZero
    // _srcChainId: the chainId that we are receiving the message from.
    // _fromAddress: the source PingPong address
    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory /*_srcAddress*/,
        uint64 /*_nonce*/,
        bytes memory _payload
    ) internal override {
        (address user, uint256 amount, address token) = abi.decode(_payload, (address, uint256, address));
        ISatBridge(satBridge).unLock(token, user, "", amount);
    }
}
