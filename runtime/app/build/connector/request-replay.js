import { LRUCache } from 'lru-cache';
/** In-flight mutations must survive both reconnects and completed-cache eviction. */
export class RequestReplayCache {
    maxPending;
    pending = new Map();
    completed;
    constructor(maxPending = 64, maxCompleted = 64) {
        this.maxPending = maxPending;
        this.completed = new LRUCache({ max: maxCompleted });
    }
    run(key, fingerprint, ttl, execute) {
        const cached = this.pending.get(key) || this.completed.get(key);
        if (cached) {
            if (cached.fingerprint !== fingerprint)
                throw new Error('secure_channel_request_conflict');
            return cached.response;
        }
        if (this.pending.size >= this.maxPending)
            throw new Error('connector_request_limit');
        // Reserve before dispatch; even a synchronous handler failure is shared.
        const response = Promise.resolve().then(execute);
        const entry = { fingerprint, response };
        this.pending.set(key, entry);
        const finish = () => {
            this.pending.delete(key);
            // TTL starts at completion, not while a long turn is still being started.
            this.completed.set(key, entry, { ttl });
        };
        void response.then(finish, finish);
        return response;
    }
}
