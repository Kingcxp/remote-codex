import { EventEmitter } from 'node:events';
const FORBIDDEN = new Set(['__proto__', 'constructor', 'prototype']);
// Both versions use the verified snapshot / Immer patch envelope. v13 adds
// Desktop metadata; keep unknown future schemas unavailable rather than guessing.
const STATE_VERSIONS = new Set([11, 13]);
// Immer's wire patches have array paths. Reject unsafe keys and broken sequences;
// never merge Desktop state into Connector configuration or forward raw snapshots.
export function applyDesktopPatches(state, patches) {
    if (!Array.isArray(patches) || patches.length > 20_000)
        throw new Error('desktop_state_invalid_patch');
    const next = { ...state };
    const copied = new WeakSet([next]);
    for (const patch of patches) {
        if (!Array.isArray(patch?.path) || !patch.path.length || !['add', 'remove', 'replace'].includes(patch.op)
            || patch.path.some((part) => (typeof part !== 'string' && typeof part !== 'number') || FORBIDDEN.has(String(part))))
            throw new Error('desktop_state_invalid_patch');
        let parent = next;
        for (const part of patch.path.slice(0, -1)) {
            if (!parent || typeof parent !== 'object' || !Object.hasOwn(parent, part))
                throw new Error('desktop_state_invalid_patch');
            const child = parent[part];
            if (!child || typeof child !== 'object')
                throw new Error('desktop_state_invalid_patch');
            if (!copied.has(child)) {
                parent[part] = Array.isArray(child) ? child.slice() : { ...child };
                copied.add(parent[part]);
            }
            parent = parent[part];
        }
        if (!parent || typeof parent !== 'object')
            throw new Error('desktop_state_invalid_patch');
        const key = patch.path.at(-1);
        if (Array.isArray(parent)) {
            if (!Number.isInteger(key) || key < 0 || key > parent.length || (patch.op !== 'add' && key === parent.length))
                throw new Error('desktop_state_invalid_patch');
            if (patch.op === 'remove')
                parent.splice(key, 1);
            else if (patch.op === 'add')
                parent.splice(key, 0, patch.value);
            else
                parent[key] = patch.value;
        }
        else {
            if (patch.op !== 'add' && !Object.hasOwn(parent, key))
                throw new Error('desktop_state_invalid_patch');
            if (patch.op === 'remove')
                delete parent[key];
            else
                parent[key] = patch.value;
        }
    }
    return next;
}
export class DesktopState extends EventEmitter {
    pipe;
    entries = new Map();
    timer;
    closed = false;
    constructor(pipe) {
        super();
        this.pipe = pipe;
        pipe.on('broadcast', message => this.receive(message));
        pipe.on('disconnected', () => {
            for (const [threadId, entry] of this.entries) {
                entry.state = null;
                entry.revision = -1;
                this.emit('invalidated', threadId);
            }
        });
        this.timer = setInterval(() => this.expire(), 15_000);
        this.timer.unref();
    }
    async read(threadId, owner, timeoutMs, fresh = false) {
        if (this.closed)
            throw new Error('desktop_state_unavailable');
        let entry = this.entries.get(threadId);
        if (!entry || entry.owner !== owner) {
            if (entry)
                this.release(threadId);
            while (this.entries.size >= 4)
                this.release(this.entries.keys().next().value);
            entry = { owner, revision: -1, state: null, touched: Date.now() };
            this.entries.set(threadId, entry);
        }
        entry.touched = Date.now();
        if (entry.pending)
            return entry.pending;
        if ((entry.retryAfter || 0) > Date.now())
            throw new Error(entry.unavailableReason || 'desktop_state_unavailable');
        if (entry.state && !fresh)
            return entry.state;
        const selected = entry;
        const reading = new Promise((resolve, reject) => {
            const done = (error, state) => {
                clearTimeout(timer);
                this.off('snapshot', received);
                this.off('invalidated', invalidated);
                error ? reject(error) : resolve(state);
            };
            const received = (id) => { if (id === threadId && this.entries.get(id) === selected && selected.state)
                done(undefined, selected.state); };
            const invalidated = (id, reason = 'desktop_state_unavailable') => { if (id === threadId)
                done(new Error(reason)); };
            const timer = setTimeout(() => done(new Error('desktop_state_timeout')), timeoutMs);
            timer.unref();
            this.on('snapshot', received);
            this.on('invalidated', invalidated);
            void this.pipe.follow(threadId, owner, true, timeoutMs).catch(error => done(error));
        });
        selected.pending = reading.catch(error => {
            // Unreadable snapshots must not cause an immediate resubscribe loop from
            // model/approval polling. Small model settings remain independently usable.
            selected.retryAfter = Date.now() + 30_000;
            selected.unavailableReason = error?.message === 'desktop_state_protocol_unsupported'
                ? error.message : 'desktop_state_unavailable';
            throw error;
        }).finally(() => { selected.pending = undefined; });
        return selected.pending;
    }
    peek(threadId, owner) {
        const entry = this.entries.get(threadId);
        return entry?.owner === owner && Date.now() - entry.touched <= 60_000 ? entry.state : null;
    }
    // Mutations are sent once. Observe their result on the existing subscription;
    // a missed notification gets one bounded snapshot recovery, never a poll loop.
    async waitFor(threadId, owner, matches, timeoutMs = 2500) {
        const current = this.peek(threadId, owner);
        if (current && matches(current))
            return current;
        const observed = await new Promise((resolve, reject) => {
            const finish = (error, state = null) => {
                clearTimeout(timer);
                this.off('changed', changed);
                this.off('invalidated', invalidated);
                error ? reject(error) : resolve(state);
            };
            const changed = (id, state, source) => {
                if (id !== threadId)
                    return;
                if (source !== owner) {
                    finish(new Error('desktop_state_unavailable'));
                    return;
                }
                if (matches(state))
                    finish(undefined, state);
            };
            const invalidated = (id) => { if (id === threadId)
                finish(new Error('desktop_state_unavailable')); };
            const timer = setTimeout(() => finish(), timeoutMs);
            this.on('changed', changed);
            this.on('invalidated', invalidated);
        });
        if (observed)
            return observed;
        const entry = this.entries.get(threadId);
        if (!entry || entry.owner !== owner)
            throw new Error('desktop_state_unavailable');
        const recovered = await this.read(threadId, owner, 5000, true);
        if (!matches(recovered))
            throw new Error('desktop_state_unconfirmed');
        return recovered;
    }
    receive(message) {
        const params = message.params;
        if (params?.hostId !== 'local' || typeof params.conversationId !== 'string')
            return;
        const id = params.conversationId, entry = this.entries.get(id);
        if (!entry || entry.owner !== message.sourceClientId)
            return;
        if (message.method === 'thread-stream-following-status-requested') {
            void this.pipe.follow(id, entry.owner, true, 1000).catch(() => { });
            return;
        }
        if (message.method !== 'thread-stream-state-changed')
            return;
        const change = params.change;
        if (!STATE_VERSIONS.has(message.version)) {
            this.invalidate(id, entry, 'desktop_state_protocol_unsupported');
            return;
        }
        if (!Number.isSafeInteger(change?.revision)) {
            this.invalidate(id, entry);
            return;
        }
        try {
            if (change.type === 'snapshot') {
                if (!change.conversationState || change.conversationState.id !== id || change.revision < entry.revision)
                    throw new Error('invalid snapshot');
                entry.state = change.conversationState;
                entry.revision = change.revision;
                entry.wireVersion = message.version;
                entry.retryAfter = undefined;
                entry.unavailableReason = undefined;
                this.emit('snapshot', id);
            }
            else if (change.type === 'patches') {
                if (change.revision <= entry.revision)
                    return;
                if (!entry.state || entry.wireVersion !== message.version || change.baseRevision !== entry.revision)
                    throw new Error('revision gap');
                entry.state = applyDesktopPatches(entry.state, change.patches);
                entry.revision = change.revision;
                if (entry.state.id !== id)
                    throw new Error('identity changed');
            }
            else
                throw new Error('invalid state change');
            // Item text/output patches cannot change controls. Keep the state current
            // without rescanning all historical turns for every streamed token.
            if (change.type === 'snapshot' || change.patches.some((patch) => !isItemPatch(patch.path))) {
                this.emit('changed', id, entry.state, entry.owner);
            }
        }
        catch {
            this.invalidate(id, entry);
        }
    }
    invalidate(id, entry, reason = 'desktop_state_unavailable') {
        entry.state = null;
        entry.revision = -1;
        entry.wireVersion = undefined;
        entry.unavailableReason = reason;
        this.emit('invalidated', id, reason);
        // The next read requests a fresh snapshot. Never guess/apply a missing revision.
    }
    expire() { for (const [id, entry] of this.entries)
        if (Date.now() - entry.touched > 60_000)
            this.release(id); }
    release(id) {
        const entry = this.entries.get(id);
        if (!entry)
            return;
        this.entries.delete(id);
        this.emit('invalidated', id);
        void this.pipe.follow(id, entry.owner, false, 1000).catch(() => { });
    }
    close() { this.closed = true; clearInterval(this.timer); for (const id of this.entries.keys())
        this.release(id); }
}
function isItemPatch(path) {
    return (path[0] === 'turns' && typeof path[1] === 'number' && path[2] === 'items')
        || (path[0] === 'turnHistory' && path[1] === 'history' && path[2] === 'entitiesByKey'
            && typeof path[3] === 'string' && path[4] === 'items');
}
