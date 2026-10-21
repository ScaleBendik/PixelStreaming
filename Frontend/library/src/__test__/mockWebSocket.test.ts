it('keeps mocked WebSockets independent of the native network transport', () => {
    const original = global.WebSocket;
    const nativeConstructor = jest.fn(() => {
        throw new Error('A unit-test socket must not open a real connection');
    });
    global.WebSocket = nativeConstructor as unknown as typeof WebSocket;
    try {
        jest.isolateModules(() => {
            const { MockWebSocketImpl } = jest.requireActual<typeof import('./mockWebSocket')>('./mockWebSocket');
            const socket = new MockWebSocketImpl('ws://localhost:24680/');
            expect(nativeConstructor).not.toHaveBeenCalled();
            expect(socket.readyState).toBe(socket.OPEN);
            const closed = jest.fn();
            socket.onclose = closed;
            socket.close(1000, 'test finished');
            expect(socket.readyState).toBe(socket.CLOSED);
            expect(closed).toHaveBeenCalledWith(expect.objectContaining({ code: 1000, reason: 'test finished' }));
        });
    } finally {
        global.WebSocket = original;
    }
});
