// SPDX-License-Identifier: Apache 2
pragma solidity >=0.8.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IWormholeReceiver.sol";
import "./interfaces/IWormholeRelayer.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/CCTPInterfaces/ITokenMessenger.sol";
import "./interfaces/CCTPInterfaces/IMessageTransmitter.sol";

abstract contract CCTPBase is OwnableUpgradeable {
    error WrongUsdcAmountReceived();
    error ExceedOneCctpMessage();
    error NotWormholeRelayer();
    error NotRegisteredContract();

    uint8 constant CCTP_KEY_TYPE = 2;

    ITokenMessenger public circleTokenMessenger;
    IMessageTransmitter public circleMessageTransmitter;
    IWormholeRelayer public wormholeRelayer;
    IWormhole public wormhole;
    address public WormholeUSDC;

    mapping(uint16 => bytes32) public registeredSenders;

    function _setWormholeBaseConfig(
        address _wormholeRelayer,
        address _wormhole,
        address _circleMessageTransmitter,
        address _circleTokenMessenger,
        address _WormholeUSDC
    ) internal {
        wormholeRelayer = IWormholeRelayer(_wormholeRelayer);
        wormhole = IWormhole(_wormhole);
        circleTokenMessenger = ITokenMessenger(_circleTokenMessenger);
        circleMessageTransmitter = IMessageTransmitter(_circleMessageTransmitter);
        WormholeUSDC = _WormholeUSDC;
    }

    modifier onlyWormholeRelayer() {
        if (msg.sender != address(wormholeRelayer)) {
            revert NotWormholeRelayer();
        }
        _;
    }

    /**
     * Sets the registered address for 'sourceChain' to 'sourceAddress'
     * So that for messages from 'sourceChain', only ones from 'sourceAddress' are valid
     *
     * Assumes only one sender per chain is valid
     * Sender is the address that called 'send' on the Wormhole Relayer contract on the source chain)
     */
    function setRegisteredSender(uint16[] calldata sourceChains, address[] calldata sourceAddresses) public onlyOwner {
        for (uint256 i = 0; i < sourceChains.length; i++) {
            registeredSenders[sourceChains[i]] = _addressToBytes32CCTP(sourceAddresses[i]);
        }
    }

    function _addressToBytes32CCTP(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}

abstract contract CCTPSender is CCTPBase {
    uint8 public constant CONSISTENCY_LEVEL_FINALIZED = 15;

    mapping(uint16 => uint32) public chainIdToCCTPDomain;

    /**
     * Sets the CCTP Domain corresponding to chain 'chain' to be 'cctpDomain'
     * So that transfers of USDC to chain 'chain' use the target CCTP domain 'cctpDomain'
     *
     * This action can only be performed by 'owner', who is set to be the deployer
     *
     * Currently, cctp domains are:
     * Ethereum: Wormhole chain id 2, cctp domain 0
     * Polgyon: Wormhole chain id 5, cctp domain 7
     * Avalanche: Wormhole chain id 6, cctp domain 1
     * Optimism: Wormhole chain id 24, cctp domain 2
     * Arbitrum: Wormhole chain id 23, cctp domain 3
     * Base: Wormhole chain id 30, cctp domain 6
     *
     * These can be set via:
     * setCCTPDomain(2, 0);
     * setCCTPDomain(5, 7);
     * setCCTPDomain(6, 1);
     * setCCTPDomain(24, 2);
     * setCCTPDomain(23, 3);
     * setCCTPDomain(30, 6);
     */
    function setCCTPDomain(uint16 chain, uint32 cctpDomain) public onlyOwner {
        chainIdToCCTPDomain[chain] = cctpDomain;
    }

    /**
     * _transferUSDC wraps common boilerplate for sending tokens to another chain using IWormholeRelayer
     * - approves the Circle TokenMessenger contract to spend 'amount' of USDC
     * - calls Circle's 'depositForBurnWithCaller'
     * - returns key for inclusion in WormholeRelayer `additionalVaas` argument
     *
     * Note: this requires that only the targetAddress can redeem transfers.
     *
     */

    function _transferUSDC(
        uint256 amount,
        uint16 targetChain,
        address targetAddress
    ) internal returns (MessageKey memory) {
        IERC20(WormholeUSDC).approve(address(circleTokenMessenger), amount);
        bytes32 targetAddressBytes32 = _addressToBytes32CCTP(targetAddress);
        uint64 nonce = circleTokenMessenger.depositForBurnWithCaller(
            amount,
            chainIdToCCTPDomain[targetChain],
            targetAddressBytes32,
            WormholeUSDC,
            targetAddressBytes32
        );
        return MessageKey(CCTP_KEY_TYPE, abi.encodePacked(chainIdToCCTPDomain[wormhole.chainId()], nonce));
    }

    // Publishes a CCTP transfer of 'amount' of USDC
    // and requests a delivery of the transfer along with 'payload' to 'targetAddress' on 'targetChain'
    //
    // The second step is done by publishing a wormhole message representing a request
    // to call 'receiveWormholeMessages' on the address 'targetAddress' on chain 'targetChain'
    // with the payload 'abi.encode(amount, payload)'
    // (and we encode the amount so it can be checked on the target chain)
    function _sendUSDCWithPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 gasLimit,
        uint256 cost,
        uint256 amount
    ) internal {
        MessageKey[] memory messageKeys = new MessageKey[](1);
        messageKeys[0] = _transferUSDC(amount, targetChain, targetAddress);

        wormholeRelayer.sendToEvm{value: cost}(
            targetChain,
            targetAddress,
            payload,
            0, // receiverValue
            0, // paymentForExtraReceiverValue
            gasLimit,
            targetChain,
            targetAddress,
            wormholeRelayer.getDefaultDeliveryProvider(),
            messageKeys,
            CONSISTENCY_LEVEL_FINALIZED
        );
    }
}

abstract contract CCTPReceiver is CCTPBase {
    function _redeemUSDC(bytes memory cctpMessage) private returns (uint256 amount) {
        (bytes memory message, bytes memory signature) = abi.decode(cctpMessage, (bytes, bytes));
        uint256 beforeBalance = IERC20(WormholeUSDC).balanceOf(address(this));
        circleMessageTransmitter.receiveMessage(message, signature);
        return IERC20(WormholeUSDC).balanceOf(address(this)) - beforeBalance;
    }

    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory additionalMessages,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external payable {
        // Currently, 'sendUSDCWithPayloadToEVM' only sends one CCTP transfer
        // That can be modified if the integrator desires to send multiple CCTP transfers
        // in which case the following code would have to be modified to support
        // redeeming these multiple transfers and checking that their 'amount's are accurate
        if (additionalMessages.length > 1) {
            revert ExceedOneCctpMessage();
        }

        uint256 amountUSDCReceived;
        if (additionalMessages.length == 1) {
            amountUSDCReceived = _redeemUSDC(additionalMessages[0]);
        }

        (uint256 amount, bytes memory userPayload) = abi.decode(payload, (uint256, bytes));

        // Check that the correct amount was received
        // It is important to verify that the 'USDC' sent in by the relayer is the same amount
        // that the sender sent in on the source chain
        if (amount != amountUSDCReceived) {
            revert WrongUsdcAmountReceived();
        }

        _onWormholeUsdcReceived(userPayload, amountUSDCReceived, sourceAddress, sourceChain, deliveryHash);
    }

    // Implement this function to handle in-bound deliveries that include a CCTP transfer
    function _onWormholeUsdcReceived(
        bytes memory payload,
        uint256 amountUSDCReceived,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) internal virtual {}
}
