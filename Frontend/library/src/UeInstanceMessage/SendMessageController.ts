// Copyright Epic Games, Inc. All Rights Reserved.

import { DataChannelSender } from '../DataChannel/DataChannelSender';
import { Logger } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';
import { StreamMessageController } from './StreamMessageController';

export class SendMessageController {
    toStreamerMessagesMapProvider: StreamMessageController;
    dataChannelSender: DataChannelSender;

    private readonly gamepadAnalogActivityValues = new Map<string, number>();

    /**
     * @param dataChannelSender - Data channel instance
     * @param toStreamerMessagesMapProvider - Stream Messages instance
     */
    constructor(
        dataChannelSender: DataChannelSender,
        toStreamerMessagesMapProvider: StreamMessageController
    ) {
        this.dataChannelSender = dataChannelSender;
        this.toStreamerMessagesMapProvider = toStreamerMessagesMapProvider;
    }

    /**
     * Send a message to the streamer through the data channel
     * @param messageType - the type of message we are sending
     * @param messageData - the message data we are sending over the data channel
     * @returns - nil
     */
    sendMessageToStreamer(messageType: string, messageData?: Array<number | string | Uint8Array>) {
        if (messageData === undefined) {
            messageData = [];
        }

        const toStreamerMessages = this.toStreamerMessagesMapProvider.toStreamerMessages;
        const messageFormat = toStreamerMessages.get(messageType);
        if (messageFormat === undefined) {
            Logger.Error(
                `Attempted to send a message to the streamer with message type: ${messageType}, but the frontend hasn't been configured to send such a message. Check you've added the message type in your cpp`
            );
            return;
        }

        if (messageFormat.structure && messageData && messageFormat.structure.length !== messageData.length) {
            Logger.Error(
                `Provided message data doesn't match expected layout. Expected [ ${messageFormat.structure
                    .map((element: string) => {
                        switch (element) {
                            case 'uint8':
                            case 'uint16':
                            case 'int16':
                            case 'float':
                            case 'double':
                            default:
                                return 'number';
                            case 'string':
                                return 'string';
                            case 'raw':
                                return 'Uint8Array';
                        }
                    })
                    .toString()} ] but received [ ${messageData
                    .map((element: number | string | Uint8Array) =>
                        element instanceof Uint8Array ? 'Uint8Array' : typeof element
                    )
                    .toString()} ]`
            );
            return;
        }

        let byteLength = 0;
        // One loop to calculate the length in bytes of all of the provided data
        messageData.forEach((element: number | string | Uint8Array, idx: number) => {
            const type = messageFormat.structure[idx];
            switch (type) {
                case 'uint8':
                    byteLength += 1;
                    break;

                case 'uint16':
                    byteLength += 2;
                    break;

                case 'int16':
                    byteLength += 2;
                    break;

                case 'float':
                    byteLength += 4;
                    break;

                case 'double':
                    byteLength += 8;
                    break;

                case 'string':
                    // 2 bytes for string length
                    byteLength += 2;
                    // 2 bytes per character
                    byteLength += 2 * (element as string).length;
                    break;

                case 'raw':
                    byteLength += (element as Uint8Array).byteLength;
                    break;
            }
        });

        const data = new DataView(new ArrayBuffer(byteLength + 1));
        data.setUint8(0, messageFormat.id);
        let byteOffset = 1;

        messageData.forEach((element: number | string | Uint8Array, idx: number) => {
            const type = messageFormat.structure[idx];
            switch (type) {
                case 'uint8':
                    data.setUint8(byteOffset, element as number);
                    byteOffset += 1;
                    break;

                case 'uint16':
                    data.setUint16(byteOffset, element as number, true);
                    byteOffset += 2;
                    break;

                case 'int16':
                    data.setInt16(byteOffset, element as number, true);
                    byteOffset += 2;
                    break;

                case 'float':
                    data.setFloat32(byteOffset, element as number, true);
                    byteOffset += 4;
                    break;

                case 'double':
                    data.setFloat64(byteOffset, element as number, true);
                    byteOffset += 8;
                    break;

                case 'string':
                    data.setUint16(byteOffset, (element as string).length, true);
                    byteOffset += 2;
                    for (let i = 0; i < (element as string).length; i++) {
                        data.setUint16(byteOffset, (element as string).charCodeAt(i), true);
                        byteOffset += 2;
                    }
                    break;

                case 'raw': {
                    const bytes = element as Uint8Array;
                    new Uint8Array(data.buffer).set(bytes, byteOffset);
                    byteOffset += bytes.byteLength;
                    break;
                }
            }
        });

        if (!this.dataChannelSender.canSend()) {
            Logger.Info(
                `Data channel cannot send yet, skipping sending message: ${messageType} - ${new Uint8Array(
                    data.buffer
                )}`
            );
            return;
        }

        this.dataChannelSender.sendData(data.buffer, this.countsAsActivity(messageType, messageData));
    }

    /**
     * Repeated gamepad polling is transport state, not evidence of new activity.
     * Keep other senders' legacy AFK behavior in this narrowly scoped fix.
     * These thresholds affect AFK only; Unreal still receives every original value.
     */
    private countsAsActivity(messageType: string, messageData: Array<number | string | Uint8Array>): boolean {
        switch (messageType) {
            case 'GamepadConnected':
                return false;
            case 'GamepadDisconnected': {
                const prefix = String(messageData[0]) + ':';
                for (const key of this.gamepadAnalogActivityValues.keys()) {
                    if (key.startsWith(prefix)) {
                        this.gamepadAnalogActivityValues.delete(key);
                    }
                }
                return false;
            }
            case 'GamepadButtonPressed':
                return messageData[2] === 0;
            case 'GamepadAnalog': {
                const value = messageData[2];
                if (typeof value !== 'number' || !Number.isFinite(value)) {
                    return false;
                }
                const key = String(messageData[0]) + ':' + String(messageData[1]);
                const previous = this.gamepadAnalogActivityValues.get(key) ?? 0;
                // Resting stick/trigger noise must not keep an unattended pad alive.
                if (Math.abs(value) <= 0.1 && Math.abs(previous) <= 0.1) {
                    this.gamepadAnalogActivityValues.set(key, value);
                    return false;
                }
                // Compare against the last significant sample so slow movement accumulates.
                if (Math.abs(value - previous) < 0.02) {
                    return false;
                }
                this.gamepadAnalogActivityValues.set(key, value);
                return true;
            }
            default:
                return true;
        }
    }
}
