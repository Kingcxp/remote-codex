import { NativeFrameReader } from './native-frame-reader.js';
import net from 'node:net';
// Matches the Desktop native app-tools host's payload limit (header excluded).
export const MAX_FRAME_BYTES = 8 * 1024 * 1024;
export class NativeRequestError extends Error {
    dispatched;
    code;
    constructor(message, dispatched, code = 'desktop_transport_error') {
        super(message);
        this.dispatched = dispatched;
        this.code = code;
    }
}
export function encodeNativeFrame(message) {
    const payload = Buffer.from(JSON.stringify(message), 'utf8');
    if (payload.length > MAX_FRAME_BYTES)
        throw new NativeRequestError('desktop_request_too_large', false);
    const frame = Buffer.allocUnsafe(payload.length + 4);
    frame.writeUInt32LE(payload.length, 0);
    payload.copy(frame, 4);
    return frame;
}
export class NativePipeClient {
    pipePath;
    socket = null;
    connected = false;
    connecting = null;
    tools = new Set();
    closed = false;
    cancelConnect = null;
    nextId = 0;
    pending = new Map();
    frames = new NativeFrameReader(MAX_FRAME_BYTES);
    constructor(pipePath) {
        this.pipePath = pipePath;
    }
    async request(method, params, timeoutMs) {
        const id = ++this.nextId;
        // Reject oversized requests before connecting or handing anything to the host.
        const frame = encodeNativeFrame({ jsonrpc: '2.0', id, method, params });
        await this.connect(timeoutMs);
        const socket = this.socket;
        if (!socket || socket.destroyed || this.closed)
            throw new NativeRequestError('desktop pipe closed', false);
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                // Expiry does not cancel host execution and must not close a shared socket.
                reject(new NativeRequestError(`${method} timeout`, true));
            }, timeoutMs);
            timer.unref?.();
            this.pending.set(id, { resolve, reject, timer });
            try {
                socket.write(frame, (error) => {
                    if (error)
                        this.disconnect(socket, error);
                });
            }
            catch (error) {
                this.disconnect(socket, error);
            }
        });
    }
    connect(timeoutMs) {
        if (this.closed)
            return Promise.reject(new NativeRequestError('desktop pipe closed', false));
        if (this.connected && this.socket && !this.socket.destroyed)
            return Promise.resolve();
        if (this.connecting)
            return this.connecting;
        this.connecting = new Promise((resolve, reject) => {
            const socket = net.createConnection(this.pipePath);
            this.socket = socket;
            const fail = (error) => {
                clearTimeout(timer);
                socket.off('connect', ready);
                this.cancelConnect = null;
                if (this.socket === socket)
                    this.socket = null;
                socket.destroy();
                reject(new NativeRequestError(error.message, false));
            };
            const ready = () => {
                clearTimeout(timer);
                this.cancelConnect = null;
                socket.off('error', fail);
                this.connected = true;
                socket.on('data', chunk => this.onData(socket, Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
                socket.on('error', error => this.disconnect(socket, error));
                socket.on('close', () => this.disconnect(socket, new Error('desktop pipe closed')));
                resolve();
            };
            const timer = setTimeout(() => fail(new Error('desktop pipe connect timeout')), timeoutMs);
            timer.unref?.();
            this.cancelConnect = () => fail(new Error('desktop pipe closed'));
            socket.once('error', fail);
            socket.once('connect', ready);
        }).finally(() => { this.connecting = null; });
        return this.connecting;
    }
    onData(socket, chunk) {
        if (socket !== this.socket)
            return;
        try {
            this.frames.push(chunk, payload => {
                let response;
                try {
                    response = JSON.parse(payload.toString('utf8'));
                    if (!response || response.jsonrpc !== '2.0')
                        throw new Error('invalid response');
                }
                catch {
                    this.disconnect(socket, new Error('desktop response invalid JSON-RPC'));
                    return false;
                }
                const pending = this.pending.get(response.id);
                if (!pending)
                    return true; // Includes late responses to expired requests.
                this.pending.delete(response.id);
                clearTimeout(pending.timer);
                if (response.error) {
                    pending.reject(new NativeRequestError(response.error.message || 'desktop request failed', true, 'desktop_host_error'));
                }
                else
                    pending.resolve(response.result);
                return this.socket === socket;
            });
        }
        catch {
            this.disconnect(socket, new Error('desktop response invalid frame size'));
        }
    }
    disconnect(socket, error) {
        if (socket !== this.socket)
            return;
        this.socket = null;
        this.connected = false;
        this.frames.clear();
        for (const pending of this.pending.values()) {
            clearTimeout(pending.timer);
            pending.reject(new NativeRequestError(error.message, true));
        }
        this.pending.clear();
        socket.destroy();
    }
    close() {
        this.closed = true;
        this.cancelConnect?.();
        if (this.socket)
            this.disconnect(this.socket, new Error('desktop pipe closed'));
    }
}
