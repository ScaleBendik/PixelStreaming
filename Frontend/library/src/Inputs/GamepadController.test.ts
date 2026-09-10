// Copyright Epic Games, Inc. All Rights Reserved.

import { StreamMessageController } from '../UeInstanceMessage/StreamMessageController';
import { GamepadController } from './GamepadController';
import { mockRTCRtpReceiver, unmockRTCRtpReceiver } from '../__test__/mockRTCRtpReceiver';
import { AFKController } from '../AFK/AFKController';
import { Config, Flags, NumericParameters } from '../Config/Config';
import { DataChannelController } from '../DataChannel/DataChannelController';
import { DataChannelSender } from '../DataChannel/DataChannelSender';
import { PixelStreaming } from '../PixelStreaming/PixelStreaming';
import { SendMessageController } from '../UeInstanceMessage/SendMessageController';

class TestGamepadEvent extends Event {
    readonly gamepad: Gamepad;
    constructor(type: string, init: GamepadEventInit) {
        super(type);
        this.gamepad = init.gamepad;
    }
}

const makeGamepad = (index: number, x = 0): Gamepad =>
    ({ index, buttons: [], axes: [x, 0] }) as unknown as Gamepad;

describe('GamepadController lifecycle', () => {
    let controller: GamepadController;
    let frames: Map<number, FrameRequestCallback>;
    let gamepads: Array<Gamepad | null>;
    let connected: jest.Mock;
    let disconnected: jest.Mock;
    let analog: jest.Mock;
    let gamepadEventDescriptor: PropertyDescriptor | undefined;
    let getGamepadsDescriptor: PropertyDescriptor | undefined;

    const connect = (index: number) => {
        const gamepad = makeGamepad(index);
        gamepads[index] = gamepad;
        window.dispatchEvent(new TestGamepadEvent('gamepadconnected', { gamepad }));
        return gamepad;
    };
    const disconnect = (gamepad: Gamepad) => {
        gamepads[gamepad.index] = null;
        window.dispatchEvent(new TestGamepadEvent('gamepaddisconnected', { gamepad }));
    };
    const runFrame = () => {
        const [id, callback] = Array.from(frames.entries())[0];
        frames.delete(id);
        callback(0);
    };

    beforeEach(() => {
        mockRTCRtpReceiver();
        frames = new Map();
        gamepads = [];
        let nextFrame = 0;
        jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
            frames.set(++nextFrame, callback);
            return nextFrame;
        });
        jest.spyOn(window, 'cancelAnimationFrame').mockImplementation((id) => { frames.delete(id); });
        gamepadEventDescriptor = Object.getOwnPropertyDescriptor(window, 'GamepadEvent');
        getGamepadsDescriptor = Object.getOwnPropertyDescriptor(navigator, 'getGamepads');
        Object.defineProperty(window, 'GamepadEvent', { configurable: true, value: TestGamepadEvent });
        Object.defineProperty(navigator, 'getGamepads', { configurable: true, value: () => gamepads });
        connected = jest.fn();
        disconnected = jest.fn();
        analog = jest.fn();
        const messages = new StreamMessageController();
        messages.toStreamerHandlers.set('GamepadConnected', connected);
        messages.toStreamerHandlers.set('GamepadDisconnected', disconnected);
        messages.toStreamerHandlers.set('GamepadAnalog', analog);
        controller = new GamepadController(messages);
        controller.register();
    });

    afterEach(() => {
        controller.unregister();
        unmockRTCRtpReceiver();
        jest.useRealTimers();
        jest.restoreAllMocks();
        if (gamepadEventDescriptor) Object.defineProperty(window, 'GamepadEvent', gamepadEventDescriptor);
        else Reflect.deleteProperty(window, 'GamepadEvent');
        if (getGamepadsDescriptor) Object.defineProperty(navigator, 'getGamepads', getGamepadsDescriptor);
        else Reflect.deleteProperty(navigator, 'getGamepads');
    });

    it('polls all connected pads once per frame without multiplying loops or duplicate connection messages', () => {
        const first = connect(0);
        connect(1);
        window.dispatchEvent(new TestGamepadEvent('gamepadconnected', { gamepad: first }));
        controller.register();

        expect(connected).toHaveBeenCalledTimes(2);
        expect(frames.size).toBe(1);
        runFrame();
        expect(analog).toHaveBeenCalledTimes(4);
        expect(frames.size).toBe(1);
    });

    it('keeps the surviving browser index and server id after another pad disconnects', () => {
        const first = connect(0);
        const second = connect(1);
        controller.onGamepadResponseReceived(30);
        controller.onGamepadResponseReceived(40);
        disconnect(first);
        expect(() => disconnect(first)).not.toThrow();
        gamepads[1] = makeGamepad(1, 0.75);
        runFrame();

        expect(disconnected).toHaveBeenCalledWith([30]);
        expect(controller.controllers[1].id).toBe(40);
        expect(analog).toHaveBeenCalledWith([40, 1, 0.75]);
        disconnect(second);
        runFrame();
        expect(frames.size).toBe(0);
    });

    it('cancels and fences retired polling callbacks across unregister and register', () => {
        connect(0);
        const retiredFrame = Array.from(frames.values())[0];
        controller.unregister();
        expect(frames.size).toBe(0);
        controller.register();
        expect(frames.size).toBe(1);

        retiredFrame(0);
        expect(analog).not.toHaveBeenCalled();
        expect(frames.size).toBe(1);
        runFrame();
        expect(analog).toHaveBeenCalledTimes(2);
    });

    it('removes the unload listener when unregistered', () => {
        controller.unregister();
        const unloadHandler = jest.fn();
        controller.beforeUnloadListener = unloadHandler;
        controller.register();
        controller.unregister();

        window.dispatchEvent(new Event('beforeunload'));
        expect(unloadHandler).not.toHaveBeenCalled();
    });

    // Exercise polling -> protocol encoding -> actual sender -> AFK, not just a classifier mock.
    const wireAfk = () => {
        jest.useFakeTimers();
        const config = new Config({ initialSettings: {
            [Flags.AFKDetection]: true,
            [NumericParameters.AFKTimeoutSecs]: 10
        } });
        const dispatchEvent = jest.fn();
        const afk = new AFKController(config, { dispatchEvent } as unknown as PixelStreaming, jest.fn());
        const timedOut = jest.fn();
        afk.onAFKTimedOutCallback = timedOut;
        const send = jest.fn();
        const channel = { dataChannel: { readyState: 'open', send } };
        const sender = new DataChannelSender({
            getDataChannelInstance: () => channel
        } as unknown as DataChannelController);
        sender.resetAfkWarningTimerOnDataSend = () => afk.resetAfkWarningTimer();
        const messages = controller.streamMessageController;
        messages.populateDefaultProtocol();
        const encoder = new SendMessageController(sender, messages);
        for (const name of messages.toStreamerMessages.keys()) {
            messages.toStreamerHandlers.set(name, data => encoder.sendMessageToStreamer(name, data));
        }
        afk.startAfkWarningTimer();
        return { afk, timedOut, send, encoder, sender, channel };
    };

    it.each([0, 0.03])('times out an attached idle controller with resting axis %s while still transmitting every frame', (rest) => {
        const { afk, timedOut, send } = wireAfk();
        connect(0);
        for (let frame = 0; frame < 700; frame++) {
            gamepads[0] = makeGamepad(0, frame % 2 ? rest : -rest);
            runFrame();
            jest.advanceTimersByTime(100);
        }
        expect(timedOut).toHaveBeenCalledTimes(1);
        expect(send).toHaveBeenCalledTimes(1401); // connection + two axes per frame
        expect(afk.active).toBe(false);
    });

    it('postpones AFK for real axis movement, but not an unchanged held axis or small jitter', () => {
        const { afk, timedOut, send } = wireAfk();
        connect(0);
        runFrame();
        jest.advanceTimersByTime(9000);
        gamepads[0] = makeGamepad(0, 0.75);
        runFrame();
        // The wire value remains exact: thresholds affect activity only.
        const encoded = new DataView(send.mock.calls[send.mock.calls.length - 2][0]);
        expect(encoded.getFloat64(3, true)).toBe(0.75);
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(false);
        for (let frame = 0; frame < 90; frame++) {
            gamepads[0] = makeGamepad(0, frame % 2 ? 0.755 : 0.75);
            runFrame();
            jest.advanceTimersByTime(100);
        }
        expect(afk.countdownActive).toBe(true);
        jest.advanceTimersByTime(60000);
        expect(timedOut).toHaveBeenCalledTimes(1);
    });

    it('counts slow cumulative axis motion and keeps controller activity samples separate', () => {
        const { afk, encoder } = wireAfk();
        encoder.sendMessageToStreamer('GamepadAnalog', [1, 1, 0.5]);
        encoder.sendMessageToStreamer('GamepadAnalog', [2, 1, -0.5]);
        jest.advanceTimersByTime(9000);
        for (const value of [0.505, 0.51, 0.515, 0.525]) {
            encoder.sendMessageToStreamer('GamepadAnalog', [1, 1, value]);
        }
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(false);
        // Polling the second, unchanged pad cannot extend that new deadline.
        jest.advanceTimersByTime(8000);
        encoder.sendMessageToStreamer('GamepadAnalog', [2, 1, -0.5]);
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(true);
    });

    it('counts a button press and release but not per-frame held-button repeats', () => {
        const { afk, timedOut, send } = wireAfk();
        connect(0);
        const buttonPad = (pressed: boolean): Gamepad => ({
            ...makeGamepad(0), buttons: [{ pressed, touched: pressed, value: pressed ? 1 : 0 }]
        });
        gamepads[0] = buttonPad(false);
        // Establish the same button layout in both snapshots.
        controller.controllers[0].prevState = buttonPad(false);
        runFrame();
        jest.advanceTimersByTime(9000);
        gamepads[0] = buttonPad(true);
        runFrame();
        jest.advanceTimersByTime(9000);
        runFrame(); // repeat: no reset
        gamepads[0] = buttonPad(false);
        runFrame(); // release: reset
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(false);
        jest.advanceTimersByTime(69000);
        expect(timedOut).toHaveBeenCalledTimes(1);
        const buttonMessages = send.mock.calls.map(([buffer]) => Array.from(new Uint8Array(buffer)))
            .filter(bytes => bytes[0] === 90 || bytes[0] === 91);
        expect(buttonMessages).toEqual([[90, 0, 0, 0], [90, 0, 0, 1], [91, 0, 0, 0]]);
    });

    it('counts trigger movement and release without counting constant trigger pressure', () => {
        const { afk, encoder } = wireAfk();
        jest.advanceTimersByTime(9000);
        encoder.sendMessageToStreamer('GamepadAnalog', [0, 5, 0.8]);
        jest.advanceTimersByTime(9000);
        encoder.sendMessageToStreamer('GamepadAnalog', [0, 5, 0.8]);
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(true);
        afk.stopAfkWarningTimer();
        afk.startAfkWarningTimer();
        jest.advanceTimersByTime(9000);
        encoder.sendMessageToStreamer('GamepadAnalog', [0, 5, 0]);
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(false);
    });

    it('does not count controller lifecycle messages or inherit analog samples after disconnection', () => {
        const { afk, encoder } = wireAfk();
        encoder.sendMessageToStreamer('GamepadAnalog', [0, 1, 0.75]);
        jest.advanceTimersByTime(9000);
        encoder.sendMessageToStreamer('GamepadDisconnected', [0]);
        encoder.sendMessageToStreamer('GamepadConnected');
        encoder.sendMessageToStreamer('GamepadAnalog', [0, 1, 0]);
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(true);
    });

    it.each(['KeyDown', 'MouseMove', 'TouchStart', 'UIInteraction', 'Command', 'XRHMDTransform'])
    ('preserves existing non-gamepad AFK behavior for %s', (name) => {
        const { afk, encoder } = wireAfk();
        // XR formats arrive from Unreal; use an equivalent registered format here.
        if (name === 'XRHMDTransform') {
            controller.streamMessageController.toStreamerMessages.set(name, { id: 110, structure: ['double'] });
        }
        const format = controller.streamMessageController.toStreamerMessages.get(name);
        const data = format.structure.map(type => type === 'string' ? '{}' : 0);
        jest.advanceTimersByTime(9000);
        encoder.sendMessageToStreamer(name, data);
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(false);
        jest.advanceTimersByTime(9000);
        expect(afk.countdownActive).toBe(true);
    });

    it('preserves direct send compatibility and does not extend AFK when the channel is closed', () => {
        const { afk, sender, channel, encoder } = wireAfk();
        jest.advanceTimersByTime(9000);
        sender.sendData(new ArrayBuffer(1));
        jest.advanceTimersByTime(9000);
        channel.dataChannel.readyState = 'closed';
        encoder.sendMessageToStreamer('KeyDown', [65, 0]);
        jest.advanceTimersByTime(1000);
        expect(afk.countdownActive).toBe(true);
    });

    it('times out while a gamepad button remains held and repeat messages continue', () => {
        const { timedOut, send } = wireAfk();
        connect(0);
        const released = { ...makeGamepad(0), buttons: [{ pressed: false, touched: false, value: 0 }] };
        controller.controllers[0].prevState = released;
        gamepads[0] = { ...released, buttons: [{ pressed: true, touched: true, value: 1 }] };
        for (let frame = 0; frame < 700; frame++) {
            runFrame();
            jest.advanceTimersByTime(100);
        }
        expect(timedOut).toHaveBeenCalledTimes(1);
        expect(send).toHaveBeenCalledTimes(2101); // connection + button and both axes each frame
    });
});
