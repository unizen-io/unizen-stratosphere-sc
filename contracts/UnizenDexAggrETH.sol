// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Controller} from "./dependencies/Controller.sol";
import {EthReceiver} from "./helpers/EthReceiver.sol";
import {IUnizenDexAggr} from "./interfaces/IUnizenDexAggr.sol";
import {IStargateRouter} from "./interfaces/IStargateRouter.sol";
import {IStargateReceiver} from "./interfaces/IStargateReceiver.sol";
import {ITcRouter} from "./interfaces/ITcRouter.sol";

contract UnizenDexAggrETH is IUnizenDexAggr, Controller, EthReceiver, ReentrancyGuardUpgradeable, IStargateReceiver {
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public stargateRouter;
    address public layerZeroEndpoint;
    address public stable;
    uint16 public stableDecimal;
    mapping(uint16 => uint16) public chainStableDecimal;
    mapping(uint16 => address) public destAddr;
    mapping(uint16 => bytes) public trustedRemoteLookup;
    mapping(uint16 => address) public poolToStableAddr;
    uint256 public dstGas;
    address public vipOracle;
    uint256 public tradingFee;
    uint256 public vipFee;
    address public treasury;
    uint256 public psFee;
    mapping(address => uint256) public _psEarned;
    mapping(string => address) public integratorAddrs;
    mapping(string => uint256) public integratorFees;
    mapping(string => uint256) public integratorUnizenSFP;
    address public feeClaimer;
    mapping(address => mapping(address => uint256)) public integratorPSEarned;
    uint256 public psShare; // psShare to KOLs
    mapping(string => uint8) public uuidType;
    uint256 public limitShare;
    mapping(address => mapping(address => uint256)) public integratorClaimed;
    mapping(address => bool) public stargateAddr;
    mapping(address => uint) public unizenFeeEarned;
    address public tcRouter;

    function initialize() external override initializer {
        __UnizenDexAggr_init();
    }

    function __UnizenDexAggr_init() internal onlyInitializing {
        __Controller_init_();
        __ReentrancyGuard_init();
        dstGas = 700000; // 700k gas for destination chain execution as default
    }

    function setStargateAddr(address _stgAddr, bool isValid) external onlyOwner {
        stargateAddr[_stgAddr] = isValid;
    }

    function setLimitShare(uint256 _limitShare) external onlyOwner {
        limitShare = _limitShare;
    }

    function setFeeClaimer(address feeClaimerAddr) external onlyOwner {
        feeClaimer = feeClaimerAddr;
    }

    function setDestAddr(uint16 chainId, address dexAggr) external onlyOwner {
        destAddr[chainId] = dexAggr;
    }

    function setStargateRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid-address");
        stargateRouter = router;
    }

    function setPoolStable(uint16 poolId, address stableAddr) external onlyOwner {
        poolToStableAddr[poolId] = stableAddr;
        if (IERC20(stableAddr).allowance(address(this), stargateRouter) == 0) {
            IERC20(stableAddr).safeApprove(stargateRouter, type(uint256).max);
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

    function setThorChainRouter(address _router) external onlyOwner {
        tcRouter = _router;
    }

    function executeSwapDstChain(address _srcToken, uint256 _srcAmount, SwapCall[] memory calls) external nonReentrant {
        require(msg.sender == address(this), "Not-unizen");
        _swap(_srcToken, _srcAmount, calls, true);
    }

    function _swap(address _srcToken, uint256 _srcAmount, SwapCall[] memory calls, bool isDstChainSwap) private {
        require(calls[0].sellToken == _srcToken, "Invalid-token");
        uint256 tempAmount;
        uint256 totalSrcAmount;
        IERC20 srcToken;
        for (uint8 i = 0; i < calls.length; ) {
            require(isWhiteListedDex(calls[i].targetExchange), "Not-verified-dex");
            if (calls[i].sellToken == _srcToken) {
                // if trade from source token
                // if not split trade, it will be calls[0]
                // if split trade, we count total amount of souce token we split into routes
                totalSrcAmount += calls[i].amount;
                require(totalSrcAmount <= _srcAmount, "Invalid-amount-to-sell");
            }
            if (calls[i].sellToken == address(0) && !isDstChainSwap) {
                // trade Ethereum, it will be for trade from source token as native, only trade single-chain as if trade dstChain, no native trade
                tempAmount = _executeTrade(
                    calls[i].targetExchange,
                    IERC20(address(0)),
                    IERC20(calls[i].buyToken),
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
                    srcToken,
                    IERC20(calls[i].buyToken),
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

    function swapSTG(
        CrossChainSwapSg memory swapInfo,
        SwapCall[] memory calls,
        SwapCall[] memory dstCalls
    ) external payable nonReentrant whenNotPaused {
        require(swapInfo.receiver != address(0), "Invalid-receiver-address");
        ContractStatus memory contractStatus = ContractStatus(0, 0, 0, 0, 0);
        IERC20 srcToken = IERC20(swapInfo.srcToken);
        IERC20 dstToken = IERC20(poolToStableAddr[swapInfo.srcPool]);
        contractStatus.balanceDstBefore = dstToken.balanceOf(address(this));
        if (!swapInfo.isFromNative) {
            srcToken.safeTransferFrom(msg.sender, address(this), swapInfo.amount);
            require(msg.value >= swapInfo.nativeFee, "Not-enough-fee");
        } else {
            require(
                msg.value >= swapInfo.amount + swapInfo.nativeFee && swapInfo.srcToken == address(0),
                "Invalid-amount"
            );
        }
        if (bytes(swapInfo.uuid).length != 0 && swapInfo.feePercent > 0) {
            swapInfo.amount =
                swapInfo.amount -
                _takeIntegratorFee(
                    swapInfo.uuid,
                    swapInfo.isFromNative,
                    srcToken,
                    swapInfo.amount,
                    swapInfo.feePercent,
                    swapInfo.sharePercent
                );
        }
        // execute trade logic
        if (calls.length > 0) {
            _swap(swapInfo.srcToken, swapInfo.amount, calls, false);
        }
        {
            // balance stable after swap, use swapInfo.amount to re-use the memory slot instead of new variables, prevent stack too deep
            contractStatus.balanceDstAfter = dstToken.balanceOf(address(this));
            swapInfo.amount = contractStatus.balanceDstAfter - contractStatus.balanceDstBefore;
            bytes memory payload;
            if (dstCalls.length != 0) {
                payload = abi.encode(
                    swapInfo.receiver,
                    swapInfo.dstToken,
                    swapInfo.actualQuote,
                    swapInfo.uuid,
                    swapInfo.userPSFee,
                    dstCalls
                );
            }

            _sendCrossChain(
                swapInfo.dstChain,
                swapInfo.srcPool,
                swapInfo.dstPool,
                msg.sender,
                swapInfo.nativeFee,
                swapInfo.amount,
                dstCalls.length == 0 ? swapInfo.receiver : destAddr[swapInfo.dstChain],
                swapInfo.gasDstChain,
                payload
            );
            emit CrossChainSwapped(swapInfo.dstChain, msg.sender, swapInfo.amount, swapInfo.apiId);
        }
    }

    function _sendCrossChain(
        uint16 dstChain,
        uint16 srcPool,
        uint16 dstPool,
        address feeReceiver,
        uint256 fee,
        uint256 amount,
        address to,
        uint256 gasDstChain,
        bytes memory payload
    ) private {
        IStargateRouter(stargateRouter).swap{value: fee}(
            dstChain,
            srcPool,
            dstPool,
            payable(feeReceiver),
            amount,
            (amount * 995) / 1000,
            IStargateRouter.lzTxObj(gasDstChain, 0, bytes("")),
            abi.encodePacked(to),
            payload
        );
    }

    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        address _token,
        uint256 amountLD,
        bytes memory payload
    ) external override {
        require(msg.sender == address(stargateRouter) || stargateAddr[msg.sender], "Only-Stargate-Router");
        require(
            _srcAddress.length == abi.encodePacked(destAddr[_chainId]).length &&
                keccak256(_srcAddress) == keccak256(abi.encodePacked(destAddr[_chainId])),
            "Unizen: Not-Unizen"
        );
        (
            address user,
            address dstToken,
            uint256 actualQuote,
            string memory uuid,
            uint16 userPSFee,
            SwapCall[] memory calls
        ) = abi.decode(payload, (address, address, uint256, string, uint16, SwapCall[]));
        ContractStatus memory contractStatus = ContractStatus(0, 0, 0, 0, 0);
        if (dstToken == address(0)) {
            // trade to ETH
            contractStatus.balanceDstBefore = address(this).balance; // eth balance of contract
        } else {
            contractStatus.balanceDstBefore = IERC20(dstToken).balanceOf(address(this));
        }
        contractStatus.balanceSrcBefore = IERC20(_token).balanceOf(address(this));
        // execute trade logic
        // if trade failed, return user stable token and end function
        try this.executeSwapDstChain(_token, amountLD, calls) {} catch {
            IERC20(_token).safeTransfer(user, amountLD);
            emit CrossChainSwapped(_chainId, user, amountLD, 0);
            return;
        }
        // _swap(_token, amountLD, calls, true);
        // Use _nocne to calculate the diff amount of stable _token left from that trade and send it to user, prevent stack too deep
        _nonce = IERC20(_token).balanceOf(address(this)) + amountLD - contractStatus.balanceSrcBefore;
        if (_nonce > 0) {
            IERC20(_token).safeTransfer(user, _nonce);
        }

        if (dstToken == address(0)) {
            // trade to ETH
            contractStatus.balanceDstAfter = address(this).balance; // eth balance of contract
            _nonce = contractStatus.balanceDstAfter - contractStatus.balanceDstBefore;
            if (_nonce > 0) {
                payable(user).sendValue(_nonce);
            }
        } else {
            contractStatus.balanceDstAfter = IERC20(dstToken).balanceOf(address(this));
            _nonce = contractStatus.balanceDstAfter - contractStatus.balanceDstBefore;
            if (_nonce > 0) {
                IERC20(dstToken).safeTransfer(user, _nonce);
            }
        }

        emit CrossChainSwapped(_chainId, user, amountLD, 0);
    }

    // *** SWAP ***swapExactOut
    function swapExactOut(
        SwapExactOutInfo memory info,
        SwapCall[] memory calls
    ) external payable whenNotPaused nonReentrant {
        uint256 amountTakenIn = info.amountInMax; // total amount included fee maxium user willing to pay
        bool isETHTrade;
        bool tradeToNative = info.dstToken == address(0) ? true : false;
        IERC20 srcToken = IERC20(info.srcToken);
        IERC20 dstToken = IERC20(info.dstToken);
        if (msg.value > 0) {
            require(amountTakenIn <= msg.value && info.srcToken == address(0), "Invalid-ETH-amount");
            isETHTrade = true;
        } else {
            srcToken.safeTransferFrom(msg.sender, address(this), amountTakenIn);
        }
        require(info.receiver != address(0), "Invalid-receiver");
        //If swap with uuid takeIntegratorFee
        if (bytes(info.uuid).length != 0 && integratorFees[info.uuid] != 0) {
            amountTakenIn =
                amountTakenIn -
                _takeIntegratorFee(info.uuid, isETHTrade, srcToken, amountTakenIn, info.feePercent, info.sharePercent);
        }
        ContractStatus memory contractStatus = ContractStatus(0, 0, 0, 0, 0);
        if (tradeToNative) {
            // swap to ETH
            contractStatus.balanceDstBefore = address(this).balance; // eth balance of contract
        } else {
            // swap to token
            contractStatus.balanceDstBefore = dstToken.balanceOf(address(this));
        }
        // execute trade logic
        _swap(info.srcToken, amountTakenIn, calls, false);
        if (tradeToNative) {
            // swap to ETH
            contractStatus.balanceDstAfter = address(this).balance; // eth balance of contract
        } else {
            // swap to token
            contractStatus.balanceDstAfter = dstToken.balanceOf(address(this));
        }
        contractStatus.totalDstAmount = contractStatus.balanceDstAfter - contractStatus.balanceDstBefore;
        require(contractStatus.totalDstAmount >= info.amountOut, "Return-amount-is-not-enough");
        if (info.dstToken != address(0)) {
            dstToken.safeTransfer(info.receiver, contractStatus.totalDstAmount);
        } else {
            payable(info.receiver).sendValue(contractStatus.totalDstAmount);
        }
        emit Swapped(
            amountTakenIn, //actualTakenIn,
            contractStatus.totalDstAmount,
            info.srcToken,
            info.dstToken,
            info.receiver,
            msg.sender,
            info.apiId
        );
    }

    function swapSimple(SwapExactInInfo memory info, SwapCall memory call) external payable whenNotPaused nonReentrant {
        bool isETHTrade;
        bool tradeToNative = info.dstToken == address(0) ? true : false;
        uint256 amount = info.amountIn;
        IERC20 srcToken = IERC20(info.srcToken);
        IERC20 dstToken = IERC20(info.dstToken);
        if (msg.value > 0) {
            require(msg.value >= amount && info.srcToken == address(0), "Invalid-amount");
            isETHTrade = true;
        } else {
            srcToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        require(info.receiver != address(0), "Invalid-receiver");
        require(info.amountOutMin > 0, "Invalid-amount-Out-min");
        // trade via Integrator or Influencer ref
        if (bytes(info.uuid).length > 0 && integratorFees[info.uuid] > 0) {
            amount =
                amount -
                _takeIntegratorFee(info.uuid, isETHTrade, srcToken, amount, info.feePercent, info.sharePercent);
        }
        require(amount >= call.amount, "Invalid-amount-trade");
        uint256 balanceUserBefore = tradeToNative ? address(info.receiver).balance : dstToken.balanceOf(info.receiver);
        {
            bool success;
            require(isWhiteListedDex(call.targetExchange), "Not-verified-dex");
            // our trade logic here is trade at a single dex and that dex will send amount of dstToken to user directly
            // dex not send token to this contract as we want to save 1 ERC20/native transfer for user
            // we only send call.amount and approve max amount to trade if erc20 is amount, already checked above
            if (isETHTrade) {
                // trade ETH
                (success, ) = call.targetExchange.call{value: call.amount}(call.data);
            } else {
                // trade ERC20
                srcToken.safeApprove(call.targetExchange, 0);
                srcToken.safeApprove(call.targetExchange, amount);
                (success, ) = call.targetExchange.call(call.data);
            }
            require(success, "Trade-failed");
        }
        uint256 balanceUserAfter = tradeToNative ? address(info.receiver).balance : dstToken.balanceOf(info.receiver);
        // use amount as memory variables to not decalre another one
        amount = balanceUserAfter - balanceUserBefore;
        require(amount >= info.amountOutMin, "Unizen: INSUFFICIENT-OUTPUT-AMOUNT");
        emit Swapped(info.amountIn, amount, info.srcToken, info.dstToken, info.receiver, msg.sender, info.apiId);
    }

    // This is a function that using for swap ULDMv3 and also the dex
    //that not support return token to info.receiver but return token to msg.sender, thats mean this contract address
    function swap(SwapExactInInfo memory info, SwapCall[] memory calls) external payable whenNotPaused nonReentrant {
        bool isETHTrade;
        bool tradeToNative = info.dstToken == address(0) ? true : false;
        uint256 amount = info.amountIn;
        IERC20 srcToken = IERC20(info.srcToken);
        IERC20 dstToken = IERC20(info.dstToken);
        if (msg.value > 0) {
            require(msg.value >= amount && info.srcToken == address(0), "Invalid-amount");
            isETHTrade = true;
        } else {
            srcToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        require(info.receiver != address(0), "Invalid-receiver");
        require(info.amountOutMin > 0, "Invalid-amount-Out-min");
        // trade via Integrator or Influencer ref
        if (bytes(info.uuid).length > 0 && integratorFees[info.uuid] > 0) {
            amount =
                amount -
                _takeIntegratorFee(info.uuid, isETHTrade, srcToken, amount, info.feePercent, info.sharePercent);
        }
        uint256 balanceDstBefore;
        if (tradeToNative) {
            // swap to ETH
            balanceDstBefore = address(this).balance; // eth balance of contract
        } else {
            // swap to token
            balanceDstBefore = dstToken.balanceOf(address(this));
        }
        // execute trade logic
        _swap(info.srcToken, amount, calls, false);
        uint256 balanceDstAfter;
        if (tradeToNative) {
            // swap to ETH
            balanceDstAfter = address(this).balance; // eth balance of contract
        } else {
            // swap to token
            balanceDstAfter = dstToken.balanceOf(address(this));
        }
        // re-use amount variables to prevent stack too deep
        amount = balanceDstAfter - balanceDstBefore;
        require(amount >= info.amountOutMin, "Return-amount-is-not-enough");

        if (tradeToNative) {
            payable(info.receiver).sendValue(amount);
        } else {
            dstToken.safeTransfer(info.receiver, amount);
        }

        emit Swapped(info.amountIn, amount, info.srcToken, info.dstToken, info.receiver, msg.sender, info.apiId);
    }

    function swapTC(SwapTC memory info, SwapCall[] memory calls) external payable whenNotPaused nonReentrant {
        require(info.amountOutMin > 0, "Invalid-amount-Out-min"); // prevent mev attack
        bool isETHTrade;
        uint256 amount = info.amountIn;
        IERC20 srcToken = IERC20(info.srcToken);
        IERC20 dstToken = IERC20(info.dstToken);
        if (msg.value > 0) {
            require(msg.value >= amount && info.srcToken == address(0), "Invalid-amount");
            isETHTrade = true;
        } else {
            srcToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        // trade via Integrator or Influencer ref
        if (bytes(info.uuid).length > 0 && info.feePercent > 0) {
            amount =
                amount -
                _takeIntegratorFee(info.uuid, isETHTrade, srcToken, amount, info.feePercent, info.sharePercent);
        }
        if (isETHTrade) {
            // deposit directly to ThorchainRouter
            ITcRouter(tcRouter).depositWithExpiry{value: amount}(
                payable(info.vault),
                address(0),
                amount,
                info.memo,
                info.deadline
            );
            emit CrossChainUTXO(address(0), info.vault, amount, info.apiId);
            return;
        }

        // execute trade logic, swap from tokens to stable
        if (calls.length > 0) {
            uint256 balanceDstBefore = dstToken.balanceOf(address(this));
            _swap(info.srcToken, amount, calls, false);
            uint256 balanceDstAfter = dstToken.balanceOf(address(this));
            uint256 totalDstAmount = balanceDstAfter - balanceDstBefore;
            require(totalDstAmount >= info.amountOutMin, "Slippage");
            dstToken.safeApprove(tcRouter, 0);
            dstToken.safeApprove(tcRouter, totalDstAmount);
            ITcRouter(tcRouter).depositWithExpiry(
                payable(info.vault),
                info.dstToken,
                totalDstAmount,
                info.memo,
                info.deadline
            );
             emit CrossChainUTXO(info.dstToken, info.vault, totalDstAmount, info.apiId);
        } else {
            // no swap, use stable
            require(info.srcToken == info.dstToken, "Wrong-Token"); 
            dstToken.safeApprove(tcRouter, 0);
            dstToken.safeApprove(tcRouter, amount);
            ITcRouter(tcRouter).depositWithExpiry(payable(info.vault), info.dstToken, amount, info.memo, info.deadline);
            emit CrossChainUTXO(info.dstToken, info.vault, amount, info.apiId);
        }
    }

    function _executeTrade(
        address _targetExchange,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellAmount,
        uint256 _nativeAmount,
        bytes memory _data
    ) internal returns (uint256) {
        uint256 balanceBeforeTrade = address(sellToken) == address(0)
            ? address(this).balance
            : sellToken.balanceOf(address(this));
        uint256 balanceBuyTokenBefore = address(buyToken) == address(0)
            ? address(this).balance
            : buyToken.balanceOf(address(this));
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = _targetExchange.call{value: _nativeAmount}(_data);
        require(success, "Call-Failed");
        uint256 balanceAfterTrade = address(sellToken) == address(0)
            ? address(this).balance
            : sellToken.balanceOf(address(this));
        require(balanceAfterTrade >= balanceBeforeTrade - sellAmount, "Some-one-steal-fund");
        uint256 balanceBuyTokenAfter = address(buyToken) == address(0)
            ? address(this).balance
            : buyToken.balanceOf(address(this));
        return (balanceBuyTokenAfter - balanceBuyTokenBefore);
    }

    function setIntegrator(
        string memory uuid,
        address integratorAddr,
        uint256 feePercent,
        uint256 share,
        uint8 _type
    ) external onlyOwner {
        require(integratorAddr != address(0));
        integratorAddrs[uuid] = integratorAddr;
        uuidType[uuid] = _type;
        if (_type == 1) {
            // integrators
            integratorFees[uuid] = feePercent;
            integratorUnizenSFP[uuid] = share;
        }
    }

    function _takeIntegratorFee(
        string memory uuid,
        bool isETHTrade,
        IERC20 token,
        uint256 amount,
        uint256 feePercent,
        uint256 sharePercent
    ) private returns (uint256 totalFee) {
        uint256 unizenFee;
        totalFee = (amount * feePercent) / 10000;
        //Collect integrator unizen shared fee
        if (sharePercent > 0) {
            unizenFee = (totalFee * sharePercent) / 10000;
            unizenFeeEarned[address(token)] = unizenFeeEarned[address(token)] + unizenFee;
        }
        if (isETHTrade) {
            payable(integratorAddrs[uuid]).sendValue(totalFee - unizenFee);
        } else {
            token.safeTransfer(integratorAddrs[uuid], totalFee - unizenFee);
        }
        return totalFee;
    }

    function getIntegratorInfor(string memory uuid) external view override returns (address, uint256, uint256) {
        return (integratorAddrs[uuid], integratorFees[uuid], integratorUnizenSFP[uuid]);
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
                integratorClaimed[integratorAddr][tokens[i]] += integratorPSEarned[integratorAddr][tokens[i]];
                integratorPSEarned[integratorAddr][tokens[i]] = 0;
            }
        }
        if (integratorPSEarned[integratorAddr][address(0)] > 0) {
            integratorAddr.call{value: integratorPSEarned[integratorAddr][address(0)]}("");
            integratorClaimed[integratorAddr][address(0)] += integratorPSEarned[integratorAddr][address(0)];
            integratorPSEarned[integratorAddr][address(0)] = 0;
        }
    }
}
