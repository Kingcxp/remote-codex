import { NativeFrameReader } from './native-frame-reader.js';
import { EventEmitter } from 'node:events';
import net from 'node:net';
import { randomUUID } from 'node:crypto';
import { encodeNativeFrame, MAX_FRAME_BYTES, NativeRequestError } from './desktop-native-pipe.js';
// Desktop's owner/follower IPC is length-prefixed JSON, NOT the app-tools JSON-RPC pipe.
// Versions are deliberately pinned: a future incompatible Desktop must fail closed.
const versions = {
    'thread-owner-discovery': 1,
    'thread-follower-read-model-settings': 1,
    'thread-follower-update-thread-settings': 2,
    'thread-follower-start-turn': 2,
    'thread-follower-steer-turn': 1,
    'thread-follower-edit-last-user-turn': 2,
    'thread-follower-load-complete-history': 1,
    'thread-follower-compact-thread': 1,
    'thread-follower-interrupt-turn': 4,
    'thread-follower-command-approval-decision': 1,
    'thread-follower-file-approval-decision': 1,
    'thread-follower-permissions-request-approval-response': 1,
    'thread-follower-submit-user-input': 1,
};
export class DesktopInputPipe extends EventEmitter {
    path;
    socket = null;
    ready = null;
    clientId = '';
    closed = false;
    frames;
    pending = new Map();
    cancelConnect = null;
    constructor(path = '\\\\.\\pipe\\codex-ipc', { stateSnapshots = false } = {}) {
        super();
        this.path = path;
        // A conversation grows with its tool output. Do not impose an application
        // size cap on local Desktop state; other channels keep their own bounds.
        this.frames = new NativeFrameReader(stateSnapshots ? null : MAX_FRAME_BYTES);
    }
    async request(method, params, timeoutMs, targetClientId) {
        const deadline = Date.now() + timeoutMs;
        // Snapshot and bound input before any asynchronous connection/initialization.
        const snapshot = JSON.parse(JSON.stringify(params));
        // Version 3 is Desktop's whole-conversation Stop: it pauses goals and
        // cleans up background tools. Version 4 targets only one expected turn.
        const version = method === 'thread-follower-interrupt-turn' && snapshot.expectedTurnId == null ? 3 : versions[method];
        encodeNativeFrame({ type: 'request', requestId: randomUUID(), sourceClientId: randomUUID(),
            method, version, params: snapshot, targetClientId });
        await this.connect(timeoutMs);
        const remaining = deadline - Date.now();
        if (remaining <= 0)
            throw new NativeRequestError(`${method} timeout`, false);
        return this.dispatch(method, version, snapshot, remaining, targetClientId);
    }
    async follow(conversationId, owner, following, timeoutMs) {
        await this.connect(timeoutMs);
        const socket = this.socket;
        if (!socket || socket.destroyed)
            throw new NativeRequestError('desktop input pipe closed', false);
        socket.write(encodeNativeFrame({ type: 'broadcast', sourceClientId: this.clientId,
            method: 'thread-stream-following-changed', version: 1, targetClientIds: [owner],
            params: { conversationId, hostId: 'local', following } }), error => { if (error)
            this.disconnect(socket, error); });
    }
    connect(timeoutMs) {
        if (this.closed)
            return Promise.reject(new NativeRequestError('desktop input pipe closed', false));
        if (this.ready)
            return this.ready;
        let connectingSocket;
        const connection = new Promise((resolve, reject) => {
            const socket = net.createConnection(this.path);
            connectingSocket = socket;
            this.socket = socket;
            const timer = setTimeout(() => fail(new Error('desktop input connect timeout')), timeoutMs);
            timer.unref?.();
            const fail = (error) => {
                clearTimeout(timer);
                this.cancelConnect = null;
                socket.off('connect', connected);
                this.disconnect(socket, error);
                reject(new NativeRequestError(error.message, false));
            };
            const connected = () => {
                clearTimeout(timer);
                this.cancelConnect = null;
                socket.off('error', fail);
                socket.on('error', error => this.disconnect(socket, error));
                socket.on('close', () => this.disconnect(socket, new Error('desktop input pipe closed')));
                socket.on('data', chunk => this.onData(socket, Buffer.from(chunk)));
                resolve();
            };
            this.cancelConnect = () => fail(new Error('desktop input pipe closed'));
            socket.once('error', fail);
            socket.once('connect', connected);
        }).then(async () => {
            const response = await this.dispatch('initialize', 0, { clientType: 'codex-anywhere' }, timeoutMs);
            if (typeof response.result?.clientId !== 'string' || !response.result.clientId) {
                throw new Error('desktop input invalid initialization');
            }
            this.clientId = response.result.clientId;
        }).catch(error => {
            if (this.socket === connectingSocket)
                this.disconnect(connectingSocket, error);
            if (this.ready === connection)
                this.ready = null;
            // Initialization cannot have delivered a user message.
            throw new NativeRequestError(error.message, false);
        });
        this.ready = connection;
        return connection;
    }
    dispatch(method, version, params, timeoutMs, targetClientId) {
        const requestId = randomUUID();
        const frame = encodeNativeFrame({ type: 'request', requestId,
            sourceClientId: this.clientId || 'initializing-client', version, method, params,
            ...(targetClientId ? { targetClientId } : {}), timeoutMs });
        const socket = this.socket;
        if (!socket || socket.destroyed || this.closed)
            return Promise.reject(new NativeRequestError('desktop input pipe closed', false));
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(requestId);
                reject(new NativeRequestError(`${method} timeout`, true));
            }, timeoutMs);
            timer.unref?.();
            this.pending.set(requestId, { method, targetClientId, resolve, reject, timer });
            try {
                socket.write(frame, error => { if (error)
                    this.disconnect(socket, error); });
            }
            catch (error) {
                this.disconnect(socket, error);
            }
        });
    }
    onData(socket, chunk) {
        if (this.socket !== socket)
            return;
        try {
            this.frames.push(chunk, payload => {
                if (this.socket !== socket)
                    return false;
                let message;
                try {
                    message = JSON.parse(payload.toString('utf8'));
                }
                catch {
                    this.disconnect(socket, new Error('desktop input invalid JSON'));
                    return false;
                }
                if (!message || typeof message.type !== 'string') {
                    this.disconnect(socket, new Error('desktop input invalid message'));
                    return false;
                }
                if (message.type === 'client-discovery-request') {
                    socket.write(encodeNativeFrame({ type: 'client-discovery-response', requestId: message.requestId,
                        response: { canHandle: false } }), error => { if (error)
                        this.disconnect(socket, error); });
                    return true;
                }
                if (message.type === 'broadcast') {
                    this.emit('broadcast', message);
                    return true;
                }
                if (message.type !== 'response')
                    return true;
                const pending = this.pending.get(message.requestId);
                if (!pending)
                    return true;
                this.pending.delete(message.requestId);
                clearTimeout(pending.timer);
                if (message.resultType === 'error') {
                    pending.reject(new NativeRequestError(String(message.error || 'desktop input rejected'), true, 'desktop_host_error'));
                }
                else if (message.resultType !== 'success' || message.method !== pending.method || !message.handledByClientId
                    || (pending.targetClientId && pending.targetClientId !== message.handledByClientId)) {
                    pending.reject(new NativeRequestError('desktop input invalid response', true));
                }
                else
                    pending.resolve(message);
                return this.socket === socket;
            });
        }
        catch {
            this.disconnect(socket, new Error('desktop input invalid frame size'));
        }
    }
    disconnect(socket, error) {
        if (this.socket !== socket)
            return;
        this.socket = null;
        this.ready = null;
        this.clientId = '';
        this.frames.clear();
        for (const pending of this.pending.values()) {
            clearTimeout(pending.timer);
            pending.reject(new NativeRequestError(error.message, true));
        }
        this.pending.clear();
        socket.destroy();
        this.emit('disconnected');
    }
    close() {
        this.closed = true;
        this.cancelConnect?.();
        if (this.socket)
            this.disconnect(this.socket, new Error('desktop input pipe closed'));
    }
}
