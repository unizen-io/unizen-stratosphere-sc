// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title IRelayer
 * @notice Sends messages from source domain to destination domain
 */
interface IRelayer {
    /**
     * @notice Sends an outgoing message from the source domain.
     * @dev Increment nonce, format the message, and emit `MessageSent` event with message information.
     * @param destinationDomain Domain of destination chain
     * @param recipient Address of message recipient on destination domain as bytes32
     * @param messageBody Raw bytes content of message
     * @return nonce reserved by message
     */
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes calldata messageBody
    ) external returns (uint64);

    /**
     * @notice Sends an outgoing message from the source domain, with a specified caller on the
     * destination domain.
     * @dev Increment nonce, format the message, and emit `MessageSent` event with message information.
     * WARNING: if the `destinationCaller` does not represent a valid address as bytes32, then it will not be possible
     * to broadcast the message on the destination domain. This is an advanced feature, and the standard
     * sendMessage() should be preferred for use cases where a specific destination caller is not required.
     * @param destinationDomain Domain of destination chain
     * @param recipient Address of message recipient on destination domain as bytes32
     * @param destinationCaller caller on the destination domain, as bytes32
     * @param messageBody Raw bytes content of message
     * @return nonce reserved by message
     */
    function sendMessageWithCaller(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        bytes calldata messageBody
    ) external returns (uint64);

    /**
     * @notice Replace a message with a new message body and/or destination caller.
     * @dev The `originalAttestation` must be a valid attestation of `originalMessage`.
     * @param originalMessage original message to replace
     * @param originalAttestation attestation of `originalMessage`
     * @param newMessageBody new message body of replaced message
     * @param newDestinationCaller the new destination caller
     */
    function replaceMessage(
        bytes calldata originalMessage,
        bytes calldata originalAttestation,
        bytes calldata newMessageBody,
        bytes32 newDestinationCaller
    ) external;
}
