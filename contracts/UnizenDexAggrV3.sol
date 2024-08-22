// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./dependencies/Controller.sol";
import "./interfaces/IUnizenDexAggrV3.sol";
import "./interfaces/IUnizenDexAggrUtils.sol";
import "./interfaces/IUnizenDexAggr.sol";
import "./interfaces/IExternalCallExecutor.sol";
import "./interfaces/IDlnSource.sol";
import "./interfaces/IMeson.sol";
import "./helpers/EthReceiver3.sol";

contract UnizenDexAggrV3Base is
    IUnizenDexAggrV3,
    OwnableUpgradeable,
    PausableUpgradeable,
    IExternalCallExecutor,
    EthReceiver3,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant BPS_DENOMINATOR = 10000;

    // unizen contract and setting
    Controller public unizenController; // actually its v1 contract addy
    address public feeClaimer;

    mapping(address => uint256) public _psEarned;
    mapping(address => mapping(address => uint256)) public integratorPSEarned;

    // DLN config
    IDlnSource public dlnSource;
    address public dlnAdapter;
    mapping(address => bool) public isDlnStable;

    IMeson public meson;
    address private _mesonCurrentAuthorizer;
    mapping(address => bool) public isMesonStable;

    mapping(address => uint) public unizenFeeEarned;

    modifier onlyDlnAdaptor() {
        require(msg.sender == dlnAdapter, "Only-Dln-Contract");
        _;
    }

    function initialize(
        IDlnSource _dlnSource,
        address _dlnAdapter,
        address _controller,
        address _feeClaimer
    ) public initializer {
        __UnizenDexAggr_init();
        dlnSource = _dlnSource;
        dlnAdapter = _dlnAdapter;
        unizenController = Controller(_controller);
        feeClaimer = _feeClaimer;
        _mesonCurrentAuthorizer = address(0);
    }

    function __Controller_init_() internal onlyInitializing {
        __Ownable_init();
        __Pausable_init();
    }

    function __UnizenDexAggr_init() internal onlyInitializing {
        __Controller_init_();
        __ReentrancyGuard_init();
    }

    // ADMIN function
    function adminPause() external onlyOwner {
        _pause();
    }

    function adminUnPause() external onlyOwner {
        _unpause();
    }

    function setUnizenController(address _controller) external onlyOwner {
        unizenController = Controller(_controller);
    }

    function setFeeClaimer(address feeClaimerAddr) external onlyOwner {
        feeClaimer = feeClaimerAddr;
    }

    function setDLNConfigution(IDlnSource _dlnSource, address _dlnAdapter) external onlyOwner {
        dlnSource = _dlnSource;
        dlnAdapter = _dlnAdapter;
    }

    function setDlnStable(address[] calldata stableTokens, bool[] calldata isActive) external onlyOwner {
        for (uint8 i = 0; i < stableTokens.length; i++) {
            isDlnStable[stableTokens[i]] = isActive[i];
        }
    }

    function setMesonConfigution(IMeson _meson) external onlyOwner {
        meson = _meson;
    }

    function setMesonStable(address[] calldata stableTokens, bool[] calldata isActive) external onlyOwner {
        for (uint8 i = 0; i < stableTokens.length; i++) {
            isMesonStable[stableTokens[i]] = isActive[i];
        }
    }

    function recoverAsset(address token) external onlyOwner {
        if (token == address(0)) {
            payable(msg.sender).sendValue(address(this).balance);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(msg.sender, balance);
        }
    }

    function revokeApprove(address token, address spender) external onlyOwner {
        IERC20(token).safeApprove(spender, 0);
    }

    /**
     * @dev function to swap cross-chain via deBridge and use stable as bridge assets
     * @param swapInfo swapInfo
     * @param calls dex trade external call
     */
    function swapDB(
        CrossChainSwapDb calldata swapInfo,
        SwapCall[] calldata calls
    ) external payable nonReentrant whenNotPaused {
        require(isDlnStable[swapInfo.srcTokenOut], "Invalid-token-out");
        bool isFromNative = swapInfo.srcToken == address(0);
        /* ======================================================
        Obtain srcToken or native
        ====================================================== */
        uint256 srcTokenAmt = swapInfo.amount;
        IERC20 srcToken;
        if (isFromNative) {
            require(msg.value >= srcTokenAmt + swapInfo.nativeFee, "Invalid-amount");
        } else {
            require(msg.value >= swapInfo.nativeFee, "Not-enough-fee");
            srcToken = IERC20(swapInfo.srcToken);
            srcToken.safeTransferFrom(msg.sender, address(this), srcTokenAmt);
        }
        // check and take Fee
        if (bytes(swapInfo.uuid).length != 0 && swapInfo.feePercent > 0) {
            srcTokenAmt =
                srcTokenAmt -
                _takeIntegratorFee(
                    swapInfo.uuid,
                    isFromNative,
                    swapInfo.srcToken,
                    srcTokenAmt,
                    swapInfo.feePercent,
                    swapInfo.sharePercent
                );
        }

        /* ======================================================
        Swap
        ====================================================== */
        uint256 balanceDstBefore = _getBalance(swapInfo.srcTokenOut);
        uint256 gotTokenOutAmt;
        if (calls.length > 0) {
            _swap(swapInfo.srcToken, srcTokenAmt, calls);
            gotTokenOutAmt = _getBalance(swapInfo.srcTokenOut) - balanceDstBefore;
            require(gotTokenOutAmt >= swapInfo.minSrcTokenOutAmt, "Not-enough-amount-out");
        } else {
            require(swapInfo.srcToken == swapInfo.srcTokenOut, "Miss-match-token-out");
            gotTokenOutAmt = srcTokenAmt;
        }

        /* ======================================================
        Send crosschain swap order
        ====================================================== */
        uint256 takeAmount = _calculateTakeAmount(
            gotTokenOutAmt,
            swapInfo.srcTokenOut == address(0),
            swapInfo.srcTokenOutDecimals,
            swapInfo.dstTokenInDecimals,
            swapInfo.dlnProtocolFeeBps,
            swapInfo.dlnTakerFeeBps,
            swapInfo.dlnOperatingExpense
        );

        uint256 nativeValue = swapInfo.nativeFee;
        if (swapInfo.srcTokenOut == address(0)) {
            nativeValue += gotTokenOutAmt;
        } else {
            IERC20(swapInfo.srcTokenOut).safeApprove(address(dlnSource), 0);
            IERC20(swapInfo.srcTokenOut).safeApprove(address(dlnSource), gotTokenOutAmt);
        }

        dlnSource.createSaltedOrder{value: nativeValue}(
            DlnOrderLib.OrderCreation({
                giveTokenAddress: swapInfo.srcTokenOut,
                giveAmount: gotTokenOutAmt,
                takeTokenAddress: abi.encodePacked(swapInfo.dstTokenIn),
                takeAmount: takeAmount,
                takeChainId: swapInfo.dstChain,
                receiverDst: abi.encodePacked(swapInfo.receiver),
                givePatchAuthoritySrc: msg.sender,
                orderAuthorityAddressDst: abi.encodePacked(msg.sender),
                allowedTakerDst: "", // empty => anyone on dst chain can fulfill the order
                externalCall: swapInfo.externalCall,
                allowedCancelBeneficiarySrc: "" // empty => sender will be account receiving token back on cancel
            }),
            swapInfo.dlnOrderSalt,
            "", // _affiliateFee
            7370, // _referralCode
            "", // _permitEnvelope
            "" // _metadata
        );

        emit DebridgeCrossChainSwapped(
            msg.sender,
            swapInfo.dstChain,
            swapInfo.srcTokenOut,
            gotTokenOutAmt,
            swapInfo.apiId
        );
    }

    function _calculateTakeAmount(
        uint256 giveAmount,
        bool useNativeCrossChain,
        uint256 srcTokenOutDecimals,
        uint256 dstTokenInDecimals,
        uint256 dlnProtocolFeeBps,
        uint256 dlnTakerFeeBps,
        uint256 operatingFee
    ) internal pure returns (uint256 takeAmt) {
        // src chain: minus DlnProtocolFee 0.04%
        if (dlnProtocolFeeBps > 0) {
            takeAmt = (giveAmount * (BPS_DENOMINATOR - dlnProtocolFeeBps)) / BPS_DENOMINATOR;
        }

        // cross chain: change token decimals when move from src chain to dst chain
        if (!useNativeCrossChain && srcTokenOutDecimals != dstTokenInDecimals) {
            if (dstTokenInDecimals > srcTokenOutDecimals) {
                takeAmt = takeAmt * 10 ** (dstTokenInDecimals - srcTokenOutDecimals);
            } else {
                takeAmt = takeAmt / 10 ** (srcTokenOutDecimals - dstTokenInDecimals);
            }
        }

        // dst chain: minus TakerMargin 0.04%
        if (dlnTakerFeeBps > 0) {
            takeAmt = (takeAmt * (BPS_DENOMINATOR - dlnTakerFeeBps)) / BPS_DENOMINATOR;
        }

        // dst chain: minus EstimatedOperatingExpenses
        takeAmt -= operatingFee;
    }

    function _getBalance(address _token) internal view returns (uint256) {
        if (_token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(_token).balanceOf(address(this));
        }
    }

    /**
     * @notice Handles the receipt of ERC20 tokens, validates and executes a function call.
     * @dev Only callable by the adapter. This function decodes the payload to extract execution data.
     *      If the function specified in the callData is prohibited, or the recipient contract is zero,
     *      all received tokens are transferred to the fallback address.
     *      Otherwise, it attempts to execute the function call. Any remaining tokens are then transferred to the fallback address.
     * @param _orderId The ID of the order that triggered this function.
     * @param _stableToken The stable token received from DlnExternalCallAdaptor
     * @param _stableAmount The amount of tokens transferred.
     * @param _receiver The address user to receive tokenOut.
     * @param _payload The encoded data containing the execution data
     *          - tokenOut: token that user want to receive
     *          - calls: swap calls to exchange _token for tokenOut
     * @return callSucceeded A boolean indicating whether the call was successful.
     * @return callResult The data returned from the call.
     */
    function onERC20Received(
        bytes32 _orderId,
        address _stableToken,
        uint256 _stableAmount,
        address _receiver,
        bytes memory _payload
    ) external onlyDlnAdaptor returns (bool callSucceeded, bytes memory callResult) {
        require(_receiver != address(0), "Invalid-receiver");

        (address tokenOut, uint256 actualQuote, string memory uuid, SwapCall[] memory calls) = abi.decode(
            _payload,
            (address, uint256, string, SwapCall[])
        );

        IERC20 stableToken = IERC20(_stableToken);
        uint256 stableBalanceBefore = stableToken.balanceOf(address(this));
        uint256 tokenOutBalanceBefore = _getBalance(tokenOut);

        try this.executeSwapDstChain(_stableToken, _stableAmount, calls) {} catch {
            stableToken.safeTransfer(_receiver, _stableAmount);
            emit DstChainSwapFailed(_orderId, _stableToken, _stableAmount, _receiver);
            return (true, callResult);
        }

        uint256 tokenOutAmt = _getBalance(tokenOut) - tokenOutBalanceBefore;
        if (tokenOutAmt > actualQuote) {
            tokenOutAmt = tokenOutAmt - _takePSFee(tokenOut, (tokenOutAmt - actualQuote), uuid, 0);
        }
        if (tokenOut == address(0)) {
            payable(_receiver).sendValue(tokenOutAmt);
        } else {
            IERC20(tokenOut).safeTransfer(_receiver, tokenOutAmt);
        }
        emit DstChainSwapSuccess(_orderId, tokenOut, tokenOutAmt, _receiver);

        /* if amount of stable received more than amount used to swap, send residual to user
            !!! reuse name 'tokenOutAmt' to avoid stack too deep, the name should be 'stableAmtSwapped'
        */
        tokenOutAmt = stableBalanceBefore - stableToken.balanceOf(address(this));
        if (_stableAmount > tokenOutAmt) {
            stableToken.safeTransfer(_receiver, _stableAmount - tokenOutAmt);
        }

        callSucceeded = true;
    }

    /**
     * @notice Handles the receipt of Ether to the contract, then validates and executes a function call.
     * @dev Only callable by the adapter. This function decodes the payload to extract execution data.
     *      If the function specified in the callData is prohibited, or the recipient contract is zero,
     *      all Ether is transferred to the fallback address.
     *      Otherwise, it attempts to execute the function call. Any remaining Ether is then transferred to the fallback address.
     * @param _orderId The ID of the order that triggered this function.
     * @param _receiver The address user to receive tokenOut.
     * @param _payload The encoded data containing the execution data
     *          - tokenOut: token that user want to receive
     *          - calls: swap calls to exchange _token for tokenOut
     * @return callSucceeded A boolean indicating whether the call was successful.
     * @return callResult The data returned from the call.
     */
    function onEtherReceived(
        bytes32 _orderId,
        address _receiver,
        bytes memory _payload
    ) external payable onlyDlnAdaptor returns (bool callSucceeded, bytes memory callResult) {
        require(_receiver != address(0), "Invalid-receiver");

        (address tokenOut, uint256 actualQuote, string memory uuid, SwapCall[] memory calls) = abi.decode(
            _payload,
            (address, uint256, string, SwapCall[])
        );

        uint256 nativeBalanceBefore = address(this).balance;
        // When call onEtherReceived, tokenOut always ERC20, not ETH => no need to use _getBalance
        IERC20 tokenOutContract = IERC20(tokenOut);
        uint256 tokenOutBalanceBefore = tokenOutContract.balanceOf(address(this));

        try this.executeSwapDstChain(address(0), msg.value, calls) {} catch {
            payable(_receiver).sendValue(msg.value);
            emit DstChainSwapFailed(_orderId, address(0), msg.value, _receiver);
            return (true, callResult);
        }

        uint256 tokenOutAmt = tokenOutContract.balanceOf(address(this)) - tokenOutBalanceBefore;
        if (tokenOutAmt > actualQuote) {
            tokenOutAmt = tokenOutAmt - _takePSFee(tokenOut, (tokenOutAmt - actualQuote), uuid, 0);
        }
        tokenOutContract.safeTransfer(_receiver, tokenOutAmt);
        emit DstChainSwapSuccess(_orderId, tokenOut, tokenOutAmt, _receiver);

        // if amount of stable received more than amount used to swap, send residual to user
        uint256 nativeSwapped = nativeBalanceBefore - address(this).balance;
        uint256 nativeResidual = msg.value - nativeSwapped;
        if (nativeResidual > 0) {
            payable(_receiver).sendValue(nativeResidual);
        }

        callSucceeded = true;
    }

    /**
     * @dev function to swap cross-chain via Meson
     * @param swapInfo swapInfo
     * @param calls dex trade external call
     */
    function swapMeson(
        CrossChainSwapMeson calldata swapInfo,
        SwapCall[] calldata calls
    ) external payable nonReentrant whenNotPaused {
        require(isMesonStable[swapInfo.srcTokenOut], "Invalid-token-out");

        bool isFromNative = swapInfo.srcToken == address(0);
        bool srcTokenOutIsNative = swapInfo.srcTokenOut == address(0);

        /* ======================================================
        Obtain srcToken or native
        ====================================================== */
        uint256 srcTokenAmt = swapInfo.amount;
        IERC20 srcToken;
        IERC20 srcTokenOutContract = IERC20(swapInfo.srcTokenOut);
        if (isFromNative) {
            require(msg.value >= srcTokenAmt, "Invalid-amount");
        } else {
            srcToken = IERC20(swapInfo.srcToken);
            srcToken.safeTransferFrom(msg.sender, address(this), srcTokenAmt);
        }

        // check and take Fee
        if (bytes(swapInfo.uuid).length != 0 && swapInfo.feePercent > 0) {
            srcTokenAmt =
                srcTokenAmt -
                _takeIntegratorFee(
                    swapInfo.uuid,
                    isFromNative,
                    swapInfo.srcToken,
                    srcTokenAmt,
                    swapInfo.feePercent,
                    swapInfo.sharePercent
                );
        }

        uint256 balanceDstBefore = _getBalance(swapInfo.srcTokenOut);
        if (calls.length > 0) {
            _swap(swapInfo.srcToken, srcTokenAmt, calls);

            uint256 gotTokenOutAmt = _getBalance(swapInfo.srcTokenOut) - balanceDstBefore;
            require(gotTokenOutAmt >= swapInfo.minSrcTokenOutAmt, "Not-enough-amount-out");

            // refund residual src token out
            uint256 residual = gotTokenOutAmt - swapInfo.minSrcTokenOutAmt;
            if (residual > 0) {
                if (srcTokenOutIsNative) {
                    payable(msg.sender).sendValue(residual);
                } else {
                    srcTokenOutContract.safeTransfer(msg.sender, residual);
                }
            }
        } else {
            require(
                swapInfo.srcTokenOut == swapInfo.srcToken && swapInfo.minSrcTokenOutAmt == swapInfo.amount,
                "Miss-match-token-out"
            );
        }

        /* ======================================================
        Send crosschain swap order
        ====================================================== */
        _mesonCurrentAuthorizer = swapInfo.initiator;
        if (srcTokenOutIsNative) {
            meson.postSwapFromContract{value: swapInfo.minSrcTokenOutAmt}(
                swapInfo.encodedSwap,
                swapInfo.postingValue,
                address(this)
            );
        } else {
            srcTokenOutContract.safeApprove(address(meson), 0);
            srcTokenOutContract.safeApprove(address(meson), swapInfo.minSrcTokenOutAmt);
            meson.postSwapFromContract(swapInfo.encodedSwap, swapInfo.postingValue, address(this));
        }
        _mesonCurrentAuthorizer = address(0);

        emit MesonCrossChainSwapped(
            msg.sender,
            swapInfo.dstChain,
            swapInfo.srcTokenOut,
            swapInfo.minSrcTokenOutAmt,
            swapInfo.apiId
        );
    }

    function executeSwapDstChain(address _srcToken, uint256 _srcAmount, SwapCall[] memory calls) external {
        require(msg.sender == address(this), "Not-unizen");
        _swap(_srcToken, _srcAmount, calls);
    }

    function _swap(address _srcToken, uint256 _srcAmount, SwapCall[] memory calls) internal {
        require(calls[0].sellToken == _srcToken, "Invalid-token");
        uint256 tempAmount;
        uint256 totalSrcAmount;
        IERC20 srcToken;
        for (uint8 i = 0; i < calls.length; ) {
            require(unizenController.isWhiteListedDex(calls[i].targetExchange), "Not-verified-dex");
            if (calls[i].sellToken == _srcToken) {
                // if trade from source token
                // if not split trade, it will be calls[0]
                // if split trade, we count total amount of souce token we split into routes
                totalSrcAmount += calls[i].amount;
                require(totalSrcAmount <= _srcAmount, "Invalid-amount-to-sell");
            }
            if (calls[i].sellToken == address(0)) {
                // trade Ethereum, it will be for trade from source token as native, only trade single-chain as if trade dstChain, no native trade
                tempAmount = _executeTrade(
                    calls[i].targetExchange,
                    address(0),
                    calls[i].buyToken,
                    calls[i].amount,
                    calls[i].amount,
                    calls[i].data
                );
            } else {
                // trade ERC20
                srcToken = IERC20(calls[i].sellToken);
                srcToken.safeApprove(calls[i].targetExchange, 0);
                srcToken.safeApprove(calls[i].targetExchange, calls[i].amount);

                tempAmount = _executeTrade(
                    calls[i].targetExchange,
                    calls[i].sellToken,
                    calls[i].buyToken,
                    calls[i].amount,
                    0,
                    calls[i].data
                );
            }
            // Here we have to check the tempAmount we got from the trade is higher than sell amount of next, else that mean we got steal fund
            // But if there is split trade with split source token into multi routes, we dont check because first trade of route is trade from source token
            // And we already check totalSrcAmount is under total amount we got
            if (i != calls.length - 1 && calls[i + 1].sellToken != _srcToken) {
                require(tempAmount >= calls[i + 1].amount, "Steal-fund");
                // the next buy token must be the current sell token
                require(calls[i].buyToken == calls[i + 1].sellToken, "Steal-funds");
            }
            unchecked {
                ++i;
            }
        }
    }

    function _executeTrade(
        address _targetExchange,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 _nativeAmount,
        bytes memory _data
    ) internal returns (uint256 gotAmount) {
        uint256 balanceBeforeTrade = _getBalance(sellToken);
        uint256 balanceBuyTokenBefore = _getBalance(buyToken);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = _targetExchange.call{value: _nativeAmount}(_data);
        require(success, "Call-Failed");
        uint256 balanceAfterTrade = _getBalance(sellToken);
        require(balanceAfterTrade >= balanceBeforeTrade - sellAmount, "Some-one-steal-fund");
        gotAmount = _getBalance(buyToken) - balanceBuyTokenBefore;
    }

    function _executeDstTrade(
        address _targetExchange,
        uint256 _nativeAmount,
        bytes memory _data
    ) internal returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = _targetExchange.call{value: _nativeAmount}(_data);
        return success;
    }

    function _takePSFee(
        address token,
        uint256 amountSlippage,
        string memory uuid,
        uint256 feePercent
    ) internal returns (uint256) {
        IUnizenDexAggr controller = IUnizenDexAggr(address(unizenController));
        uint256 psAmount = (amountSlippage * controller.psFee()) / 10000;
        if (bytes(uuid).length == 0) {
            // no uuid
            _psEarned[token] = _psEarned[token] + psAmount;
            return psAmount;
        }
        uint8 _type = controller.uuidType(uuid);
        address integratorAddr = controller.integratorAddrs(uuid);
        if (_type == 2) {
            // KOLs
            uint256 shares = controller.psShare();
            integratorPSEarned[integratorAddr][token] += (psAmount * shares) / 10000;
            amountSlippage = psAmount;
            psAmount = psAmount - (psAmount * shares) / 10000;
            _psEarned[token] = _psEarned[token] + psAmount;
            return amountSlippage;
        } else if (_type == 1) {
            // integrator
            if (feePercent <= IUnizenDexAggrUtils(address(unizenController)).limitShare()) {
                // if they take fee less than or equal limitShare, we share them PS
                integratorPSEarned[integratorAddr][token] += (amountSlippage - psAmount);
                _psEarned[token] = _psEarned[token] + psAmount;
                return amountSlippage;
            }
            _psEarned[token] = _psEarned[token] + psAmount;
            return psAmount;
        }
    }

    function _takeIntegratorFee(
        string memory uuid,
        bool isETHTrade,
        address token,
        uint256 amount,
        uint256 feePercent,
        uint256 sharePercent
    ) internal returns (uint256 totalFee) {
        uint256 unizenFee;
        address integratorAddrs = IUnizenDexAggr(address(unizenController)).integratorAddrs(uuid);

        totalFee = (amount * feePercent) / 10000;

        //Collect integrator unizen shared fee
        if (sharePercent > 0) {
            unizenFee = (totalFee * sharePercent) / 10000;
            unizenFeeEarned[address(token)] = unizenFeeEarned[address(token)] + unizenFee;
        }
        if (isETHTrade) {
            payable(integratorAddrs).sendValue(totalFee - unizenFee);
        } else {
            IERC20(token).safeTransfer(integratorAddrs, totalFee - unizenFee);
        }

        return totalFee;
    }

    function unizenWithdrawPS(address payable receiver, address[] calldata tokens) external onlyOwner {
        require(receiver != address(0), "Invalid-address");
        for (uint256 i; i < tokens.length; i++) {
            if (_psEarned[tokens[i]] > 0) {
                IERC20(tokens[i]).safeTransfer(receiver, _psEarned[tokens[i]]);
                _psEarned[tokens[i]] = 0;
            }
        }
        if (_psEarned[address(0)] > 0) {
            receiver.call{value: _psEarned[address(0)]}("");
            _psEarned[address(0)] = 0;
        }
    }

    function unizenWithdrawEarnedFee(address payable receiver, address[] calldata tokens) external onlyOwner {
        for (uint256 i; i < tokens.length; i++) {
            if (unizenFeeEarned[tokens[i]] > 0) {
                IERC20(tokens[i]).safeTransfer(receiver, unizenFeeEarned[tokens[i]]);
                unizenFeeEarned[tokens[i]] = 0;
            }
        }

        if (unizenFeeEarned[address(0)] > 0) {
            receiver.call{value: unizenFeeEarned[address(0)]}("");
            unizenFeeEarned[address(0)] = 0;
        }
    }

    function integratorsWithdrawPS(address[] calldata tokens) external nonReentrant {
        address integratorAddr = msg.sender;
        for (uint256 i; i < tokens.length; i++) {
            if (integratorPSEarned[integratorAddr][tokens[i]] > 0) {
                IERC20(tokens[i]).safeTransfer(integratorAddr, integratorPSEarned[integratorAddr][tokens[i]]);
                integratorPSEarned[integratorAddr][tokens[i]] = 0;
            }
        }
        if (integratorPSEarned[integratorAddr][address(0)] > 0) {
            integratorAddr.call{value: integratorPSEarned[integratorAddr][address(0)]}("");
            integratorPSEarned[integratorAddr][address(0)] = 0;
        }
    }
}
