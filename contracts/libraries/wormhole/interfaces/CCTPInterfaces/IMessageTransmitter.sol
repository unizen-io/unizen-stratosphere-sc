// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "./IRelayer.sol";
import "./IReceiver.sol";

/**
 * @title IMessageTransmitter
 * @notice Interface for message transmitters, which both relay and receive messages.
 */
interface IMessageTransmitter is IRelayer, IReceiver {}
