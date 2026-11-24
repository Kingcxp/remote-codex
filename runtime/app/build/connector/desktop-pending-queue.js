import { readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
function entry(message, id, input, createdAt) {
    const content = Array.isArray(input) ? input : [];
    const context = message.context || {};
    const status = message.submission?.status;
    return { id, text: content.length ? content.filter(i => i?.type === 'text').map(i => String(i.text || '')).join('\n')
            : typeof message.text === 'string' ? message.text : typeof context.prompt === 'string' ? context.prompt : '',
        hasImage: content.some(i => /^(image|localImage|local_image)$/.test(i?.type)) || Boolean(context.imageAttachments?.length),
        hasFiles: Boolean(context.fileAttachments?.length || context.addedFiles?.length),
        createdAt: Number.isFinite(createdAt ?? message.createdAt) ? Number(createdAt ?? message.createdAt) : null,
        status: status === 'outcome-unknown' ? 'unknown' : message.pausedReason ? 'paused'
            : status === 'submitting' || status === 'sending' ? 'sending' : 'queued',
        ...(message.pausedReason ? { reason: String(message.pausedReason) } : {}) };
}
/** Read Desktop's durable queues only. Never rewrite its global state or consume a submission. */
export class DesktopPendingQueue {
    home;
    constructor(home = process.env.CODEX_HOME || join(homedir(), '.codex')) {
        this.home = home;
    }
    async list(threadId) {
        const results = await Promise.allSettled([this.server(threadId), this.legacy(threadId)]);
        const entries = [], seen = new Set();
        for (const result of results)
            if (result.status === 'fulfilled')
                for (const item of result.value) {
                    // Server receipts may temporarily coexist with a legacy restoration entry.
                    if (item.identities.some(id => seen.has(id)))
                        continue;
                    item.identities.forEach(id => seen.add(id));
                    entries.push(item.entry);
                }
        return { entries, available: results.every(r => r.status === 'fulfilled') };
    }
    async legacy(threadId) {
        let raw;
        try {
            raw = await readFile(join(this.home, '.codex-global-state.json'), 'utf8');
        }
        catch (error) {
            if (error.code === 'ENOENT')
                return [];
            throw error;
        }
        const state = JSON.parse(raw);
        const messages = state['queued-follow-ups']?.[threadId] ?? [];
        if (!Array.isArray(messages))
            throw new Error('desktop_queue_schema_changed');
        return messages.map((message) => {
            if (!message || typeof message.id !== 'string')
                throw new Error('desktop_queue_schema_changed');
            return { entry: entry(message, `desktop:${message.id}`),
                identities: [message.id, message.serverQueuedMessageId, message.submission?.clientUserMessageId].filter(Boolean) };
        });
    }
    async server(threadId) {
        const path = join(this.home, 'queue_1.sqlite');
        try {
            await stat(path);
        }
        catch (error) {
            if (error.code === 'ENOENT')
                return [];
            throw error;
        }
        const { DatabaseSync } = await import('node:sqlite');
        const db = new DatabaseSync(path, { readOnly: true });
        try {
            db.exec('PRAGMA busy_timeout=50');
            const rows = db.prepare('SELECT id, payload_json, created_at_ms FROM queued_items WHERE thread_id = ? ORDER BY queue_order, id').all(threadId);
            return rows.flatMap(row => {
                const payload = JSON.parse(String(row.payload_json));
                // Other queue payloads are internal actions, not user messages.
                if (!payload.UserInput)
                    return [];
                const id = String(row.id), message = payload.UserInput;
                return [{ entry: entry({}, `desktop:${id}`, message.content, Number(row.created_at_ms)),
                        identities: [id, message.client_id].filter(Boolean) }];
            });
        }
        finally {
            db.close();
        }
    }
}
