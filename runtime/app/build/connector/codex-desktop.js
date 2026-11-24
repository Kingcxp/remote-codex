import { DesktopControls } from './desktop-controls.js';
import { DesktopUserInput } from './desktop-user-input.js';
import { readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { NativePipeClient, NativeRequestError, encodeNativeFrame } from './desktop-native-pipe.js';
import { desktopQueueState } from './desktop-queue-state.js';
import { normalizeSessionName } from '../shared/session-name.js';
// Desktop split app tools from browser control in newer builds. Prefer the
// dedicated host, but retain capability-checked discovery for older versions.
const PIPE_PREFIXES = ['codex-app-tools-', 'codex-browser-use-'];
const DEFAULT_TIMEOUT_MS = 15_000;
const STATUS_ENRICHMENT_TIMEOUT_MS = 1_000;
const TASK_SCOPED_TOOLS = new Set(['send_message_to_thread', 'set_thread_title', 'read_thread', 'set_thread_archived']);
function appThreadReady(value) {
    const status = value.thread.status;
    return ['idle', 'completed'].includes(String(status?.type || status || 'unknown')) && !status?.activeFlags?.length;
}
export class CodexDesktopClient {
    timeoutMs;
    client;
    discovery = null;
    generation = 0;
    userInput;
    controls;
    readLatestTurn;
    constructor(options = {}) {
        this.timeoutMs = Number.isFinite(options.timeoutMs)
            ? Math.max(1_000, Number(options.timeoutMs)) : DEFAULT_TIMEOUT_MS;
        this.client = null;
        this.readLatestTurn = options.readLatestTurn;
        this.userInput = new DesktopUserInput((threadId, timeoutMs) => this.openThread({ threadId }, timeoutMs), this.timeoutMs);
        this.controls = new DesktopControls(this.userInput);
    }
    async sendMessage({ threadId, text, requestId, model, thinking, imagePath }) {
        const targetThreadId = requireThreadId(threadId);
        const prompt = String(text || '').trim();
        if (!prompt)
            throw new Error('message_required');
        await this.deliverMessage({ threadId: targetThreadId, text: prompt, requestId, ...(imagePath ? { imagePath } : {}),
            model: String(model || '').trim() || undefined,
            thinking: String(thinking || '').trim() || undefined,
        });
        return { threadId: targetThreadId, delivery: 'desktop' };
    }
    // Some Desktop releases expose app-tools but no owner/follower IPC. Only
    // switch transports after a proven pre-dispatch failure, never after a lost ACK.
    async deliverMessage(input, queued = false) {
        try {
            return await (queued ? this.userInput.startQueued(input) : this.userInput.steerQueued(input));
        }
        catch (error) {
            if (!['desktop_input_unavailable', 'desktop_input_unsupported', 'desktop_input_not_ready'].includes(error.message))
                throw error;
        }
        if (input.imagePath)
            throw new Error('desktop_image_unsupported');
        let before, previous;
        try {
            before = await this.readAppThread(input.threadId, false);
            if (queued && !appThreadReady(before))
                throw new Error('desktop_queue_busy');
            previous = await this.latestQueueTurn(input.threadId);
            if (queued && previous?.status === 'inProgress')
                throw new Error('desktop_queue_busy');
        }
        catch (error) {
            if (error.message === 'desktop_queue_busy')
                throw error;
            throw new Error('desktop_input_unavailable');
        }
        const status = String(before.thread.status?.type || before.thread.status || 'unknown');
        let result;
        try {
            result = await this.callTool({ tool: 'send_message_to_thread',
                arguments: { threadId: input.threadId, prompt: input.text,
                    ...(input.model ? { model: input.model } : {}), ...(input.thinking ? { thinking: input.thinking } : {}) },
                callerThreadId: input.threadId, callId: `bridge-input-${String(input.requestId)}` });
        }
        catch (error) {
            if (error instanceof NativeRequestError && error.dispatched)
                throw new Error('desktop_delivery_unknown');
            throw new Error('desktop_input_unavailable');
        }
        // App-tools acknowledges submission, not the next turn ID. Keep a barrier
        // until a different turn is observed completed; idle alone cannot drain FIFO.
        let payload;
        try {
            payload = parseToolPayload(result);
        }
        catch {
            throw new Error('desktop_delivery_unknown');
        }
        if (result.success !== true || payload.threadId !== input.threadId)
            throw new Error('desktop_delivery_unknown');
        return { turnId: !queued && status === 'active' && previous?.id ? previous.id
                : 'app-tools-after:' + Buffer.from(previous?.id || '').toString('base64url') };
    }
    async readAppThread(threadId, includeTurns = true) {
        const result = await this.callTool({ tool: 'read_thread', arguments: {
                threadId, includeTurns, turnLimit: 1, includeOutputs: false, maxOutputCharsPerItem: 1_000,
            }, callerThreadId: threadId, callId: `bridge-state-${randomUUID()}` });
        if (result.success !== true)
            throw new Error('desktop_thread_read_failed');
        let value;
        try {
            value = parseToolPayload(result);
        }
        catch {
            throw new Error('desktop_thread_read_failed');
        }
        if (value.thread?.id !== threadId || !Array.isArray(value.turns))
            throw new Error('desktop_thread_read_failed');
        return value;
    }
    async latestQueueTurn(threadId) {
        // The connector already reads bounded rollout tails. Their lifecycle IDs
        // avoid loading a single huge turn through the size-limited app-tools host.
        if (this.readLatestTurn)
            return this.readLatestTurn(threadId);
        const value = await this.readAppThread(threadId), turn = value.turns[0];
        return turn ? { id: String(turn.id), status: String(turn.status) } : null;
    }
    async queueState(threadId, previousTurnId) {
        try {
            const state = (await this.controls.snapshot(threadId, true, true)).state;
            if (!previousTurnId?.startsWith('app-tools-after:'))
                return desktopQueueState(state, previousTurnId);
        }
        catch (error) {
            if (!['desktop_input_unavailable', 'desktop_input_unsupported', 'desktop_input_not_ready'].includes(error.message))
                throw error;
        }
        const value = await this.readAppThread(threadId, false);
        const ready = appThreadReady(value);
        if (!ready || !previousTurnId)
            return { ready, previousTurnComplete: !previousTurnId };
        const turn = await this.latestQueueTurn(threadId);
        const completed = Boolean(turn && ['completed', 'interrupted', 'failed'].includes(turn.status));
        const baseline = previousTurnId?.startsWith('app-tools-after:')
            ? Buffer.from(previousTurnId.slice('app-tools-after:'.length), 'base64url').toString() : null;
        const previousTurnComplete = completed && (baseline !== null ? turn.id !== baseline : turn.id === previousTurnId);
        return { ready: ready && turn?.status !== 'inProgress', previousTurnComplete };
    }
    async readHistory(threadId) {
        try {
            return await this.controls.readHistory(threadId);
        }
        catch (error) {
            if (!['desktop_input_unavailable', 'desktop_input_unsupported', 'desktop_input_not_ready'].includes(error.message))
                throw error;
        }
        // read_thread returns bounded previews, not complete message snapshots.
        // Keep the full rollout page instead of replacing it with clipped output.
        return null;
    }
    async renameThread({ threadId, name }) {
        const targetThreadId = requireThreadId(threadId);
        const title = normalizeSessionName(name);
        let result;
        try {
            result = await this.callTool({
                tool: 'set_thread_title',
                arguments: { threadId: targetThreadId, title },
                callerThreadId: targetThreadId,
                callId: `bridge-rename-${randomUUID()}`,
            });
        }
        catch (error) {
            const desktopError = error;
            if (desktopError?.message === 'desktop_thread_identity_mismatch')
                throw error;
            if (desktopError?.message.startsWith('desktop_tool_unavailable:'))
                throw error;
            if (/timeout/i.test(String(desktopError?.message || error)))
                throw new Error('desktop_rename_timeout');
            if (desktopError?.code === 'desktop_host_error') {
                throw new Error(`desktop_rename_failed:${desktopError.message || 'unknown error'}`);
            }
            throw new Error('desktop_app_unavailable');
        }
        if (result?.success !== true) {
            const message = result?.contentItems?.map((item) => item?.text).filter(Boolean).join('\n');
            throw new Error(`desktop_rename_failed:${message || 'unknown error'}`);
        }
        return { threadId: targetThreadId, title };
    }
    async openThread({ threadId }, timeoutMs = this.timeoutMs) {
        const targetThreadId = requireThreadId(threadId);
        const result = await this.callTool({
            tool: 'navigate_to_codex_page',
            arguments: { threadId: targetThreadId },
            callerThreadId: targetThreadId,
            callId: `bridge-open-${randomUUID()}`,
        }, { timeoutMs });
        if (result?.success !== true)
            throw new Error('desktop_thread_open_failed');
        return { threadId: targetThreadId, opened: true };
    }
    async workspaceLibrary(callerThreadId) {
        const caller = requireThreadId(callerThreadId);
        const call = async (tool, args) => {
            const reply = await this.callTool({ tool, arguments: args, callerThreadId: caller, callId: `bridge-library-${randomUUID()}` });
            if (reply.success !== true)
                throw new Error('desktop_library_unavailable');
            return parseToolPayload(reply);
        };
        const [projectData, recent] = await Promise.all([call('list_projects', {}), call('list_threads', { limit: 50 })]);
        const threads = new Map();
        for (const archived of [false, true]) {
            let cursor;
            const seen = new Set();
            do {
                const page = await call('list_threads', { mode: 'history', source: 'codex', hostId: 'local', archived, limit: 50, ...(cursor ? { cursor } : {}) });
                for (const thread of page.threads || [])
                    if (thread.kind === 'codex' && thread.hostId === 'local') {
                        threads.set(thread.id, { id: thread.id, projectId: thread.projectId || null });
                    }
                cursor = page.nextCursor || undefined;
                if (cursor && seen.has(cursor))
                    throw new Error('desktop_library_pagination_failed');
                if (cursor)
                    seen.add(cursor);
            } while (cursor);
        }
        const pinned = new Set((recent.pinnedThreads || []).filter((t) => t.kind === 'codex').map((t) => t.id));
        return { projects: (projectData.projects || []).filter((p) => !p.hostId || p.hostId === 'local').map((p) => ({
                id: p.projectId, name: p.title || p.displayName || p.name || String(p.path || '').split(/[\\/]/).pop() || p.projectId,
                path: p.path || '', isGitRepository: p.isGitRepository === true,
            })), threads: [...threads.values()].map(t => ({ ...t, pinned: pinned.has(t.id) })) };
    }
    async manageThread(threadId, operation, value) {
        const id = requireThreadId(threadId);
        const tool = operation === 'pin' ? 'set_thread_pinned' : 'move_thread_to_project';
        const args = operation === 'pin' ? { threadId: id, source: 'codex', pinned: value === true }
            : { threadId: id, source: 'codex', hostId: 'local', projectId: value == null ? null : String(value) };
        const reply = await this.callTool({ tool, arguments: args, callerThreadId: id, callId: `bridge-manage-${randomUUID()}` });
        if (reply.success !== true)
            throw new Error('desktop_library_update_failed');
        return { threadId: id, updated: true, ...parseToolPayload(reply) };
    }
    async archiveThread({ threadId, cancelPendingApproval = false }) {
        const targetThreadId = requireThreadId(threadId);
        const state = await this.readThreadState({ threadId: targetThreadId });
        const confirmedWaiting = cancelPendingApproval === true && state.waitingOnApproval
            && ['active', 'running', 'inProgress', 'waiting'].includes(state.status);
        if (!confirmedWaiting && (state.waitingOnApproval || !['idle', 'completed', 'error', 'notLoaded'].includes(state.status))) {
            throw new Error('session_archive_not_idle');
        }
        const result = await this.callTool({
            tool: 'set_thread_archived',
            arguments: { threadId: targetThreadId, archived: true, source: 'codex' },
            callerThreadId: targetThreadId,
            callId: `bridge-archive-${randomUUID()}`,
        });
        if (result?.success !== true)
            throw new Error('desktop_thread_archive_failed');
        return { threadId: targetThreadId, archived: true };
    }
    async restoreThread({ threadId }) {
        const targetThreadId = requireThreadId(threadId);
        const result = await this.callTool({
            tool: 'set_thread_archived',
            arguments: { threadId: targetThreadId, archived: false, source: 'codex' },
            callerThreadId: targetThreadId,
            callId: `bridge-restore-${randomUUID()}`,
        });
        if (result?.success !== true)
            throw new Error('desktop_thread_restore_failed');
        return { threadId: targetThreadId, archived: false };
    }
    async listThreads({ callerThreadId, limit = 50 } = {}) {
        const caller = String(callerThreadId || '').trim();
        if (!caller)
            return [];
        // Background enrichment must tolerate a cold Desktop list without delaying
        // the session response. Capability probes still use the shorter deadline.
        const result = await this.callTool({
            tool: 'list_threads',
            arguments: { limit: Math.min(50, Math.max(1, Number(limit) || 50)) },
            callerThreadId: caller,
            callId: `bridge-list-${randomUUID()}`,
        }, { timeoutMs: DEFAULT_TIMEOUT_MS });
        if (result?.success !== true)
            throw new Error('desktop_thread_list_failed');
        const payload = parseToolPayload(result);
        const rows = [
            ...(Array.isArray(payload?.pinnedThreads) ? payload.pinnedThreads : []),
            ...(Array.isArray(payload?.threads) ? payload.threads : []),
        ];
        return rows.filter((thread) => thread?.kind === 'codex' && thread?.id).map((thread) => ({
            id: String(thread.id),
            status: String(thread.status || 'unknown'),
        }));
    }
    async readThreadState({ threadId }) {
        const targetThreadId = requireThreadId(threadId);
        const result = await this.callTool({
            tool: 'read_thread',
            arguments: {
                threadId: targetThreadId,
                turnLimit: 1,
                includeOutputs: false,
                maxOutputCharsPerItem: 1_000,
            },
            callerThreadId: targetThreadId,
            callId: `bridge-read-state-${randomUUID()}`,
        });
        if (result?.success !== true)
            throw new Error('desktop_thread_read_failed');
        const payload = parseToolPayload(result);
        const status = payload?.thread?.status;
        const activeFlags = Array.isArray(status?.activeFlags) ? status.activeFlags.map(String) : [];
        return {
            status: String(status?.type || status || 'unknown'),
            waitingOnApproval: activeFlags.includes('waitingOnApproval'),
        };
    }
    async callTool({ tool, arguments: toolArguments, callerThreadId, callId }, options = {}) {
        // Snapshot before the asynchronous pipe lookup, so the validated target
        // cannot be replaced while a connection is being established.
        const argumentsSnapshot = { ...toolArguments };
        // A bridge request is never an inter-task delegation. Fail before opening
        // the Desktop pipe if a task-scoped call tries to borrow another identity.
        if (TASK_SCOPED_TOOLS.has(tool) || Object.hasOwn(argumentsSnapshot, 'threadId')) {
            const target = requireThreadId(argumentsSnapshot.threadId);
            if (target !== argumentsSnapshot.threadId || target !== callerThreadId) {
                throw new Error('desktop_thread_identity_mismatch');
            }
        }
        const timeoutMs = Number.isFinite(options.timeoutMs)
            ? Math.max(250, Number(options.timeoutMs)) : this.timeoutMs;
        const client = await this.getClient(timeoutMs);
        if (!client.tools.has(tool))
            throw new Error(`desktop_tool_unavailable:${tool}`);
        return client.request('tools/call', {
            arguments: argumentsSnapshot,
            // Newer Desktop hosts require the caller's backing kind. This bridge
            // only delivers to Codex tasks, so never take it from browser input.
            callerSource: 'codex',
            callId,
            namespace: 'codex_app',
            threadId: callerThreadId,
            tool,
            turnId: callId,
        }, timeoutMs);
    }
    async getClient(timeoutMs = this.timeoutMs) {
        if (this.client?.connected)
            return this.client;
        if (this.discovery)
            return this.discovery;
        const generation = this.generation;
        const discovery = this.discoverClient(timeoutMs).then(client => {
            if (generation !== this.generation) {
                client?.close();
                throw new Error('desktop_app_unavailable');
            }
            if (!client)
                throw new Error('desktop_app_unavailable');
            this.client?.close();
            this.client = client;
            return client;
        }).finally(() => {
            if (this.discovery === discovery)
                this.discovery = null;
        });
        this.discovery = discovery;
        return discovery;
    }
    async discoverClient(timeoutMs) {
        if (process.platform !== 'win32')
            throw new Error('desktop_app_unavailable');
        let names;
        try {
            names = await readdir('\\\\.\\pipe\\');
        }
        catch {
            throw new Error('desktop_app_unavailable');
        }
        return discoverDesktopClient(names, name => probePipe(`\\\\.\\pipe\\${name}`, Math.min(timeoutMs, 5_000)));
    }
    async getCapabilities() {
        const [appTools, input] = await Promise.allSettled([
            this.getClient(STATUS_ENRICHMENT_TIMEOUT_MS),
            this.userInput.pipe.connect(STATUS_ENRICHMENT_TIMEOUT_MS),
        ]);
        return {
            available: appTools.status === 'fulfilled',
            tools: appTools.status === 'fulfilled' ? [...appTools.value.tools] : [],
            inputAvailable: input.status === 'fulfilled',
        };
    }
    close() {
        this.userInput.close();
        this.generation++;
        this.discovery = null;
        this.client?.close();
        this.client = null;
    }
}
async function discoverDesktopClient(names, probe) {
    for (const prefix of PIPE_PREFIXES) {
        const candidates = await Promise.all(names.filter(name => name.startsWith(prefix)).map(probe));
        const client = candidates.find(Boolean);
        for (const candidate of candidates) {
            if (candidate && candidate !== client)
                candidate.close();
        }
        if (client)
            return client;
    }
    return null;
}
function requireThreadId(value) {
    if (typeof value !== 'string')
        throw new Error('thread_id_required');
    const id = value.trim();
    if (!id || id.length > 256 || /[\0\r\n]/.test(id))
        throw new Error('thread_id_required');
    return id;
}
async function probePipe(pipePath, timeoutMs) {
    const client = new NativePipeClient(pipePath);
    try {
        const result = await client.request('tools/list', { threadStartKind: 'all' }, timeoutMs);
        client.tools = new Set((Array.isArray(result?.tools) ? result.tools : [])
            .filter((tool) => tool.namespace === 'codex_app' && typeof tool.name === 'string')
            .map((tool) => tool.name));
        if (!client.tools.has('send_message_to_thread')) {
            client.close();
            return null;
        }
        return client;
    }
    catch {
        client.close();
        return null;
    }
}
function parseToolPayload(result) {
    for (const candidate of [result?.structuredContent, result?.data, result?.output]) {
        if (candidate && typeof candidate === 'object')
            return candidate;
    }
    for (const item of Array.isArray(result?.contentItems) ? result.contentItems : []) {
        if (item?.json && typeof item.json === 'object')
            return item.json;
        if (typeof item?.text !== 'string')
            continue;
        try {
            const parsed = JSON.parse(item.text);
            if (parsed && typeof parsed === 'object')
                return parsed;
        }
        catch { /* try the next content item */ }
    }
    throw new Error('desktop_thread_list_invalid');
}
export function mergeDesktopSessionStatuses(sessions, desktopThreads, locallyActiveThreadIds = []) {
    const statuses = new Map((desktopThreads || []).map((thread) => [thread.id, thread.status]));
    const active = new Set(typeof locallyActiveThreadIds === 'string' ? [locallyActiveThreadIds] : locallyActiveThreadIds);
    return (sessions || []).map((session) => {
        if (active.has(session.id))
            return { ...session, status: 'active' };
        return statuses.has(session.id)
            ? { ...session, status: statuses.get(session.id) }
            : session;
    });
}
export const internals = { encodeNativeFrame, parseToolPayload, discoverDesktopClient, probePipe };
