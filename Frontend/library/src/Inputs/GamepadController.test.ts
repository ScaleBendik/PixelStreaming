// Copyright Epic Games, Inc. All Rights Reserved.

import { StreamMessageController } from '../UeInstanceMessage/StreamMessageController';
import { GamepadController } from './GamepadController';

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
});
