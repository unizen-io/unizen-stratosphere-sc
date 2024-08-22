// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {UnizenDexAggrV3Base} from "./UnizenDexAggrV3.sol";
import "./libraries/wormhole/CCTPBase.sol";

/**
 * UnizenDexAggrV3 version 3: integrate Wormhole
 */
contract UnizenDexAggrV3 is UnizenDexAggrV3Base, CCTPSender, CCTPReceiver {
    using SafeERC20 for IERC20;
    using Address for address payable;

    function setWormholeConfig(
        address _wormholeRelayer,
        address _wormhole,
        address _circleMessageTransmitter,
        address _circleTokenMessenger,
        address _WormholeUSDC
    ) external onlyOwner {
        _setWormholeBaseConfig(
            _wormholeRelayer,
            _wormhole,
            _circleMessageTransmitter,
            _circleTokenMessenger,
            _WormholeUSDC
        );

        setCCTPDomain(2, 0);
        setCCTPDomain(5, 7);
        setCCTPDomain(6, 1);
        setCCTPDomain(24, 2);
        setCCTPDomain(23, 3);
        setCCTPDomain(30, 6);
    }

    /**
     * @dev function to swap cross-chain via Wormhole
     * @param swapInfo Wormhole swapInfo
     * @param calls dex trade external call
     */
    function swapWormhole(
        CrossChainSwapWormhole calldata swapInfo,
        SwapCall[] calldata calls,
        SwapCall[] calldata dstCalls
    ) external payable nonReentrant whenNotPaused {
        if (registeredSenders[swapInfo.wormholeDstChain] != _addressToBytes32CCTP(swapInfo.dstChainAggr)) {
            revert NotRegisteredContract();
        }

        uint256 gotSrcTokenAmt = _obtainSrcToken(
            swapInfo.srcToken,
            swapInfo.amount,
            swapInfo.nativeFee,
            swapInfo.uuid,
            swapInfo.feePercent,
            swapInfo.sharePercent
        );

        uint256 gotTokenOutAmt = _executeSrcTrade(
            swapInfo.srcToken,
            gotSrcTokenAmt,
            WormholeUSDC,
            swapInfo.minSrcTokenOutAmt,
            calls
        );

        /* ======================================================
        Send crosschain swap order
        ====================================================== */
        bytes memory payload = abi.encode(
            swapInfo.receiver,
            swapInfo.dstToken,
            swapInfo.minDstTokenAmt,
            swapInfo.uuid,
            dstCalls
        );
        bytes memory relayerPayload = abi.encode(gotTokenOutAmt, payload);

        _sendUSDCWithPayloadToEvm(
            swapInfo.wormholeDstChain,
            swapInfo.dstChainAggr,
            relayerPayload,
            swapInfo.dstChainGasLimit,
            swapInfo.nativeFee,
            gotTokenOutAmt
        );

        emit WormholeCrossChainSwapped(
            msg.sender,
            swapInfo.wormholeDstChain,
            WormholeUSDC,
            gotTokenOutAmt,
            swapInfo.apiId
        );
    }

    /**
     * @notice Debridge destination chain handler function.
     * @param _payload arbitrary crosschain data
     * @param _stableAmount amount of USDC received
     * @param _srcAddress address of sender contract on source chain - in bytes32 format
     * @param _srcChain source chain Wormhole's id
     */
    function _onWormholeUsdcReceived(
        bytes memory _payload,
        uint256 _stableAmount,
        bytes32 _srcAddress,
        uint16 _srcChain,
        bytes32 // deliveryHash
    ) internal override onlyWormholeRelayer {
        if (registeredSenders[_srcChain] != _srcAddress) {
            revert NotRegisteredContract();
        }

        (
            address receiver,
            address tokenOut,
            uint256 minTokenOutQuote,
            string memory uuid,
            SwapCall[] memory calls
        ) = abi.decode(_payload, (address, address, uint256, string, SwapCall[]));

        require(receiver != address(0), "Invalid-receiver");

        IERC20 stableToken = IERC20(WormholeUSDC);
        uint256 stableBalanceBefore = stableToken.balanceOf(address(this));
        uint256 tokenOutBalanceBefore = _getBalance(tokenOut);

        try this.executeSwapDstChain(address(stableToken), _stableAmount, calls) {} catch {
            stableToken.safeTransfer(receiver, _stableAmount);
            emit WormholeDstChainSwapFailed(address(stableToken), _stableAmount, receiver);
            return;
        }

        uint256 tokenOutAmt = _getBalance(tokenOut) - tokenOutBalanceBefore;
        if (tokenOutAmt > minTokenOutQuote) {
            tokenOutAmt = tokenOutAmt - _takePSFee(tokenOut, (tokenOutAmt - minTokenOutQuote), uuid, 0);
        }
        if (tokenOut == address(0)) {
            payable(receiver).sendValue(tokenOutAmt);
        } else {
            IERC20(tokenOut).safeTransfer(receiver, tokenOutAmt);
        }
        emit WormholeDstChainSwapSuccess(tokenOut, tokenOutAmt, receiver);

        /* if amount of stable received more than amount used to swap, send residual to user
            !!! reuse name 'tokenOutAmt' to avoid stack too deep, the name should be 'stableAmtSwapped'
        */
        tokenOutAmt = stableBalanceBefore - stableToken.balanceOf(address(this));
        if (_stableAmount > tokenOutAmt) {
            stableToken.safeTransfer(receiver, _stableAmount - tokenOutAmt);
        }
    }

    function _obtainSrcToken(
        address srcToken,
        uint256 srcTokenAmt,
        uint256 nativeFee,
        string memory uuid,
        uint256 feePercent,
        uint256 sharePercent
    ) private returns (uint256 gotSrcTokenAmt) {
        bool isFromNative = srcToken == address(0);

        if (isFromNative) {
            require(msg.value >= srcTokenAmt + nativeFee, "Invalid-amount");
        } else {
            require(msg.value >= nativeFee, "Not-enough-fee");
            IERC20(srcToken).safeTransferFrom(msg.sender, address(this), srcTokenAmt);
        }

        // check and take Fee
        if (bytes(uuid).length != 0 && feePercent > 0) {
            srcTokenAmt =
                srcTokenAmt -
                _takeIntegratorFee(uuid, isFromNative, srcToken, srcTokenAmt, feePercent, sharePercent);
        }

        gotSrcTokenAmt = srcTokenAmt;
    }

    function _executeSrcTrade(
        address srcToken,
        uint256 srcTokenAmt,
        address srcTokenOut,
        uint256 minSrcTokenOutAmt,
        SwapCall[] calldata calls
    ) internal returns (uint256 gotTokenOutAmt) {
        if (calls.length > 0) {
            uint256 balanceDstBefore = _getBalance(srcTokenOut);
            _swap(srcToken, srcTokenAmt, calls);
            gotTokenOutAmt = _getBalance(srcTokenOut) - balanceDstBefore;
            require(gotTokenOutAmt >= minSrcTokenOutAmt, "Not-enough-amount-out");
        } else {
            require(srcToken == srcTokenOut, "Miss-match-token-out");
            return srcTokenAmt;
        }
    }
}
