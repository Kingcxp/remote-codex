import { open } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { proposedPlanText } from '../shared/proposed-plan.js';
import { parseUserMessage, parseAssistantMessage, parseInjectedUserMessage } from '../shared/message-content.js';
const CHUNK = 128 * 1024;
// Walk physical JSONL records backwards. Cursors are byte offsets, so pages
// remain stable while Desktop appends new messages and across context compaction.
export async function readMessageHistory(filePath, threadId, options = {}) {
    const file = await open(filePath, 'r');
    try {
        const size = (await file.stat()).size;
        let saved;
        if (typeof options.cursor === 'string' && options.cursor.startsWith('messages:v1:')) {
            try {
                saved = JSON.parse(Buffer.from(options.cursor.slice(12), 'base64url').toString());
            }
            catch {
                throw new Error('history_cursor_invalid');
            }
            if (saved?.threadId !== threadId || saved.query !== String(options.query || '').trim().toLocaleLowerCase()
                || saved.role !== String(options.role || 'all'))
                throw new Error('history_cursor_invalid');
        }
        let end = saved ? Number(saved.offset) : options.cursor == null ? size : Number(options.cursor);
        if (!Number.isSafeInteger(end) || end < 0 || end > size)
            throw new Error('history_cursor_invalid');
        const initialEnd = end;
        const query = String(options.query || '').trim().toLocaleLowerCase();
        if (query.length > 300)
            throw new Error('history_query_too_long');
        const role = String(options.role || 'all');
        if (!['all', 'user', 'assistant', 'reasoning'].includes(role))
            throw new Error('history_role_invalid');
        const limit = Math.min(80, Math.max(1, Number(options.limit) || 40));
        const budget = options.scanBytes ?? 8 * 1024 * 1024;
        const messages = [];
        let pending = Buffer.alloc(0), position = end, currentTurnId = String(saved?.turnId || ''), responseBytes = 0;
        let previous = { identity: String(saved?.identity || ''), source: String(saved?.source || '') };
        const cursor = () => end > 0 ? 'messages:v1:' + Buffer.from(JSON.stringify({ threadId, query, role, offset: end,
            turnId: currentTurnId, ...previous })).toString('base64url') : null;
        while (position > 0 || pending.length) {
            if (position > 0) {
                const start = Math.max(0, position - CHUNK);
                const buffer = Buffer.alloc(position - start);
                await file.read(buffer, 0, buffer.length, start);
                pending = pending.length ? Buffer.concat([buffer, pending]) : buffer;
                position = start;
            }
            let lineEnd = pending.length;
            for (let i = pending.length - 1; i >= -1; i--) {
                if (i >= 0 && pending[i] !== 10)
                    continue;
                if (i < 0 && position > 0)
                    break;
                const lineStart = i + 1;
                const offset = position + lineStart;
                const bytes = pending.subarray(lineStart, lineEnd);
                lineEnd = i;
                end = offset;
                let row;
                try {
                    row = JSON.parse(bytes.toString('utf8'));
                }
                catch {
                    continue;
                }
                const payload = row.payload || {};
                if (payload.type === 'task_started' || payload.type === 'task_complete')
                    previous = { identity: '', source: '' };
                currentTurnId = String(payload.turn_id || payload.turnId || row.turn_id || currentTurnId);
                const item = historyMessageFromRow(row, threadId, currentTurnId, offset);
                if (item && (role === 'all' || item.role === role) && (!query || item.text.toLocaleLowerCase().includes(query))) {
                    // Event/response pairs represent the same message. Match only adjacent
                    // copies in this page; repeated user messages remain separate records.
                    const identity = createHash('sha256').update(JSON.stringify([item.role, item.phase, item.text])).digest('hex');
                    if (previous.identity !== identity || previous.source === row.type) {
                        if (item.text.length > 512_000) {
                            const hit = query ? item.text.toLocaleLowerCase().indexOf(query) : 0;
                            const start = Math.max(0, hit - 1000);
                            item.text = (start ? '…' : '') + item.text.slice(start, start + 512_000) + '\n…（此消息过长，显示部分内容）';
                            item.truncated = true;
                        }
                        messages.push(item);
                        responseBytes += Buffer.byteLength(item.text);
                    }
                    previous = { identity, source: row.type };
                }
                else if (item)
                    previous = { identity: '', source: '' };
                if (messages.length >= limit || responseBytes >= 2 * 1024 * 1024 || initialEnd - end >= budget) {
                    return { threadId, messages, nextCursor: cursor(), scannedBytes: initialEnd - end };
                }
            }
            pending = lineEnd >= 0 ? Buffer.from(pending.subarray(0, lineEnd)) : Buffer.alloc(0);
            if (position === 0)
                break;
        }
        return { threadId, messages, nextCursor: null, scannedBytes: initialEnd };
    }
    finally {
        await file.close();
    }
}
export function historyMessageFromRow(row, threadId, turnId, offset) {
    const p = row.payload || {};
    let role, phase = '', text = '';
    if (row.type === 'event_msg' && p.type === 'user_message') {
        role = 'user';
        text = p.message || p.text || '';
    }
    if (row.type === 'event_msg' && p.type === 'agent_message') {
        role = 'assistant';
        phase = p.phase || 'commentary';
        text = p.message || p.text || '';
    }
    if (row.type === 'event_msg' && p.type === 'agent_reasoning') {
        role = 'reasoning';
        phase = 'analysis';
        text = p.text || '';
    }
    if (row.type === 'response_item' && p.type === 'reasoning' && Array.isArray(p.summary)) {
        role = 'reasoning';
        phase = 'analysis';
        text = p.summary.map((v) => typeof v === 'string' ? v : v.text || '').join('\n');
    }
    if (row.type === 'response_item' && p.type === 'message' && ['user', 'assistant'].includes(p.role)) {
        role = p.role;
        phase = role === 'assistant' ? p.phase || 'commentary' : '';
        text = (p.content || []).map((v) => v.text || v.input_text || v.output_text || '').filter(Boolean).join('\n');
    }
    const injected = row.type === 'response_item' ? parseInjectedUserMessage(p) : null;
    if (injected) {
        role = 'user';
        text = injected.text;
    }
    if (row.type === 'response_item' && p.type === 'plan') {
        role = 'assistant';
        phase = 'final_answer';
        text = p.text || '';
    }
    if (row.type === 'event_msg' && p.type === 'item_completed' && p.item?.type === 'plan') {
        role = 'assistant';
        phase = 'final_answer';
        text = p.item.text || '';
    }
    if (!role || !text)
        return null;
    const plan = role === 'assistant' ? proposedPlanText(text) : null;
    if (plan !== null) {
        text = plan;
        phase = 'final_answer';
    }
    text = (role === 'user' ? parseUserMessage(text) : parseAssistantMessage(text)).text;
    if (!text.trim())
        return null;
    return { id: createHash('sha256').update(`${threadId}:${offset}`).digest('hex').slice(0, 24), threadId, turnId,
        role, phase, text, timestamp: String(row.timestamp || ''), offset };
}
