import { BaseMessage } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';

export interface MockWebSocketSpyFunctions {
    constructorSpy: null | ((url: string) => void);
    openSpy: null | ((event: Event) => void);
    errorSpy: null | ((event: Event) => void);
    closeSpy: null | ((event: CloseEvent) => void);
    messageSpy: null | ((event: MessageEvent) => void);
    messageBinarySpy: null | ((event: MessageEvent) => void);
    sendSpy: null | ((data: string | Blob | ArrayBufferView | ArrayBufferLike) => void);
}

export interface MockWebSocketTriggerFunctions {
    triggerOnOpen: null | (() => void);
    triggerOnError: null | (() => void);
    triggerOnClose: null | ((closeReason?: CloseEventInit) => void);
    triggerOnMessage: null | ((message?: BaseMessage) => void);
    triggerOnMessageBinary: null | ((message?: Blob) => void);
    triggerRemoteClose: null | ((code?: number, reason?: string) => void);
}

const spyFunctions: MockWebSocketSpyFunctions = {
    constructorSpy: null,
    openSpy: null,
    errorSpy: null,
    closeSpy: null,
    messageSpy: null,
    messageBinarySpy: null,
    sendSpy: null
};

const triggerFunctions: MockWebSocketTriggerFunctions = {
    triggerOnOpen: null,
    triggerOnError: null,
    triggerOnClose: null,
    triggerOnMessage: null,
    triggerOnMessageBinary: null,
    triggerRemoteClose: null
};

// Do not extend the native WebSocket: its constructor opens a real connection,
// allowing local services and network events to interfere with unit tests.
export class MockWebSocketImpl extends EventTarget implements WebSocket {
    static readonly CONNECTING = 0;
    static readonly OPEN = 1;
    static readonly CLOSING = 2;
    static readonly CLOSED = 3;
    readonly CONNECTING = 0;
    readonly OPEN = 1;
    readonly CLOSING = 2;
    readonly CLOSED = 3;
    readonly url: string;
    readonly protocol: string;
    readonly extensions = '';
    readonly bufferedAmount = 0;
    binaryType: BinaryType = 'blob';
    onopen: WebSocket['onopen'] = null;
    onclose: WebSocket['onclose'] = null;
    onerror: WebSocket['onerror'] = null;
    onmessage: WebSocket['onmessage'] = null;
    onmessagebinary?: WebSocket['onmessagebinary'];
    _readyState: number;

    constructor(url: string | URL, protocols?: string | string[]) {
        super();
        this.url = new URL(url).toString();
        this.protocol = typeof protocols === 'string' ? protocols : protocols?.[0] ?? '';
        this._readyState = this.OPEN;
        spyFunctions.constructorSpy?.(this.url);
        triggerFunctions.triggerOnOpen = this.triggerOnOpen.bind(this);
        triggerFunctions.triggerOnError = this.triggerOnError.bind(this);
        triggerFunctions.triggerOnClose = this.triggerOnClose.bind(this);
        triggerFunctions.triggerOnMessage = this.triggerOnMessage.bind(this);
        triggerFunctions.triggerOnMessageBinary = this.triggerOnMessageBinary.bind(this);
        triggerFunctions.triggerRemoteClose = this.triggerRemoteClose.bind(this);
    }

    get readyState() {
        return this._readyState;
    }

    close(code?: number | undefined, reason?: string | undefined): void {
        this._readyState = this.CLOSED;
        this.triggerOnClose({ code, reason });
    }

    send(data: string | Blob | ArrayBufferView | ArrayBufferLike): void {
        spyFunctions.sendSpy?.(data);
    }

    triggerOnOpen() {
        const event = new Event('open');
        this.onopen?.(event);
        spyFunctions.openSpy?.(event);
    }

    triggerOnError() {
        const event = new Event('error');
        this.onerror?.(event);
        spyFunctions.errorSpy?.(event);
    }

    triggerOnClose(closeReason?: CloseEventInit) {
        const reason = closeReason ?? { code: 1, reason: 'mock reason' };
        const event = new CloseEvent('close', reason);
        this.onclose?.(event);
        spyFunctions.closeSpy?.(event);
    }

    triggerRemoteClose(code?: number, reason?: string) {
        this.close(code, reason);
    }

    triggerOnMessage(message: BaseMessage) {
        const data = JSON.stringify(message);
        const event = new MessageEvent('message', { data });
        this.onmessage?.(event);
        spyFunctions.messageSpy?.(event);
    }

    triggerOnMessageBinary(message?: Blob) {
        const data =
            message ??
            new Blob([JSON.stringify({ type: 'test' })], {
                type: 'application/json'
            });
        const event = new MessageEvent('messagebinary', { data });
        this.onmessagebinary?.(event);
        spyFunctions.messageBinarySpy?.(event);
    }
}

const originalWebSocket = WebSocket;
export const mockWebSocket = (): [
    MockWebSocketSpyFunctions,
    MockWebSocketTriggerFunctions
] => {
    spyFunctions.constructorSpy = jest.fn();
    spyFunctions.openSpy = jest.fn();
    spyFunctions.errorSpy = jest.fn();
    spyFunctions.closeSpy = jest.fn();
    spyFunctions.messageSpy = jest.fn();
    spyFunctions.messageBinarySpy = jest.fn();
    spyFunctions.sendSpy = jest.fn();
    global.WebSocket = MockWebSocketImpl;
    return [spyFunctions, triggerFunctions];
};

export const unmockWebSocket = () => {
    global.WebSocket = originalWebSocket;
    spyFunctions.constructorSpy = null;
    spyFunctions.openSpy = null;
    spyFunctions.errorSpy = null;
    spyFunctions.closeSpy = null;
    spyFunctions.messageSpy = null;
    spyFunctions.messageBinarySpy = null;
};
