import { createHash } from 'node:crypto';
import { classifyDesktopError } from './desktop-user-input.js';
import { measureOperation } from './operation-metrics.js';
import { desktopPermissionConfig, desktopPermissionSettings } from './desktop-permissions.js';
import { desktopHistorySnapshot } from './desktop-history.js';
import { userInputQuestions, userInputAnswers } from '../shared/user-input.js';
import { isMcpToolApproval } from './app-server-permissions.js';
import { DesktopPendingQueue } from './desktop-pending-queue.js';
function mutationError(error) {
    const classified = classifyDesktopError(error, true);
    return classified.message === 'desktop_delivery_unknown' ? new Error('desktop_operation_unknown') : classified;
}
const approvalMethods = {
    'item/commandExecution/requestApproval': 'thread-follower-command-approval-decision',
    'item/fileChange/requestApproval': 'thread-follower-file-approval-decision',
    'item/permissions/requestApproval': 'thread-follower-permissions-request-approval-response',
};
function approvalId(owner, request) {
    return 'desktop:' + createHash('sha256').update(JSON.stringify([owner, request.id, request.method, request.params])).digest('hex');
}
export function desktopSummary(state, owner) {
    const status = String(state.threadRuntimeStatus?.type || 'unknown');
    let active;
    if (status === 'active') {
        for (const turn of conversationTurns(state)) {
            if (turn?.status === 'inProgress' && typeof turn.turnId === 'string'
                && (!active || (turn.turnStartedAtMs || 0) > (active.turnStartedAtMs || 0)))
                active = turn;
        }
    }
    const turnId = status === 'active' ? active?.turnId || null : null;
    const approvals = (Array.isArray(state.requests) ? state.requests : [])
        .filter((r) => Object.hasOwn(approvalMethods, r.method) && r.id != null)
        .map((r) => {
        const summary = JSON.stringify(r.params ?? {}, null, 2);
        const decisions = r.params?.availableDecisions;
        const supported = !Array.isArray(decisions) || decisions.includes('accept');
        return { approvalId: approvalId(owner, r), threadId: state.id, turnId: r.params?.turnId || turnId,
            kind: r.method, source: 'desktop', actionable: supported && summary.length <= 24_000,
            summary: summary.slice(0, 24_000) };
    });
    const userInputRequests = (Array.isArray(state.requests) ? state.requests : []).flatMap((r) => {
        if (r.method !== 'item/tool/requestUserInput' || r.id == null || isMcpToolApproval(r.method, r.params || {})
            || r.params?.threadId && r.params.threadId !== state.id)
            return [];
        const questions = userInputQuestions(r.params?.questions);
        return questions ? [{ id: approvalId(owner, r), threadId: state.id, turnId: r.params?.turnId || turnId, questions }] : [];
    });
    return { threadId: state.id, status, turnId, canStop: status === 'active' || state.threadGoal?.status === 'active',
        goal: state.threadGoal || null,
        collaborationMode: state.latestCollaborationMode?.mode || state.latestThreadSettings?.collaborationMode?.mode || 'default',
        waitingOnApproval: (state.requests || []).length > 0, approvals, userInputRequests,
        model: state.latestCollaborationMode?.settings?.model || state.latestModel || '',
        reasoningEffort: state.latestCollaborationMode?.settings?.reasoning_effort
            ?? state.latestThreadSettings?.collaborationMode?.settings?.reasoning_effort
            ?? state.latestThreadSettings?.effort ?? state.latestReasoningEffort ?? '',
        serviceTier: state.latestThreadSettings?.serviceTier ?? state.latestServiceTier ?? 'default' };
}
function* conversationTurns(state) {
    yield* state.turns || [];
    const entities = state.turnHistory?.history?.entitiesByKey || {};
    for (const key in entities)
        if (Object.hasOwn(entities, key))
            yield entities[key];
}
export class DesktopControls {
    input;
    pendingQueue;
    historyProgress = new Map();
    constructor(input, pendingQueue = new DesktopPendingQueue()) {
        this.input = input;
        this.pendingQueue = pendingQueue;
    }
    readQueue(threadId) { return this.pendingQueue.list(threadId); }
    async snapshot(threadId, fresh = false, open = true) {
        try {
            const owner = await this.input.owner(threadId, open);
            const state = await this.input.state.read(threadId, owner.id, 5000, fresh);
            return { state, owner: owner.id, summary: desktopSummary(state, owner.id) };
        }
        catch (error) {
            if (error.message.startsWith('desktop_state_'))
                throw error;
            throw classifyDesktopError(error, false);
        }
    }
    async read(threadId, open = false) { return (await this.snapshot(threadId, false, open)).summary; }
    async readHistory(threadId) {
        const snapshot = desktopHistorySnapshot((await this.snapshot(threadId, false, false)).state);
        if (!snapshot || snapshot.turn.status !== 'inProgress') {
            this.historyProgress.delete(threadId);
            return snapshot;
        }
        // Streamed text can change without a new item timestamp. Remember observed
        // visible changes across browser refreshes; identical polls are not progress.
        const signature = createHash('sha256').update(JSON.stringify([
            snapshot.activityKind, snapshot.activityDetail, snapshot.turn.items,
        ])).digest('hex');
        const previous = this.historyProgress.get(threadId);
        const sameTurn = previous?.turnId === snapshot.activityId ? previous : undefined;
        const updatedAt = Math.max(snapshot.activityUpdatedAt || 0, sameTurn?.updatedAt || 0, sameTurn && sameTurn.signature !== signature ? Date.now() : 0);
        this.historyProgress.delete(threadId);
        this.historyProgress.set(threadId, { turnId: snapshot.activityId, signature, updatedAt });
        while (this.historyProgress.size > 4)
            this.historyProgress.delete(this.historyProgress.keys().next().value);
        return { ...snapshot, activityUpdatedAt: updatedAt || null };
    }
    async permissions(threadId, capabilities) {
        return desktopPermissionConfig((await this.snapshot(threadId, false, false)).state, capabilities);
    }
    async updatePermissions(threadId, value, capabilities) {
        const before = await this.snapshot(threadId, true, false);
        if (before.summary.status === 'active' || before.state.requests?.length || before.state.threadGoal?.status === 'active') {
            throw new Error('permission_mode_turn_active');
        }
        if (before.summary.status !== 'idle')
            throw new Error('desktop_permissions_unavailable');
        const config = desktopPermissionConfig(before.state, capabilities);
        if (!value.settingsToken || config.settingsToken !== value.settingsToken)
            throw new Error('desktop_settings_changed');
        const settings = desktopPermissionSettings(value.mode, before.state, capabilities);
        try {
            const reply = await this.input.pipe.request('thread-follower-update-thread-settings', {
                conversationId: threadId, threadSettings: settings,
            }, 15000, before.owner);
            if (reply.result?.applied !== true)
                throw new Error('desktop_settings_changed');
        }
        catch (error) {
            if (error.message === 'desktop_settings_changed')
                throw error;
            throw mutationError(error);
        }
        // Desktop normalizes writable roots after its optimistic settings patch.
        // Read its canonical configuration once so the returned conflict token does
        // not immediately become stale. Do not assert caller-supplied roots survived.
        const after = await this.input.state.read(threadId, before.owner, 5000, true)
            .catch(() => { throw new Error('desktop_settings_unconfirmed'); });
        const confirmed = desktopPermissionConfig(after, capabilities);
        const sandbox = after.latestThreadSettings.sandboxPolicy;
        if (confirmed.mode !== value.mode || (value.mode !== 'full' && sandbox.networkAccess !== capabilities.networkAccess)) {
            throw new Error('desktop_settings_unconfirmed');
        }
        return confirmed;
    }
    editing = new Set();
    async editMessage(threadId, turnId, message) {
        if (this.editing.has(threadId))
            throw new Error('message_edit_busy');
        this.editing.add(threadId);
        try {
            let before = await this.snapshot(threadId, true, false);
            if (before.summary.status !== 'idle' || before.state.requests?.length || before.state.threadGoal?.status === 'active') {
                throw new Error('message_edit_busy');
            }
            if (![...conversationTurns(before.state)].some(turn => turn.turnId === turnId)) {
                await this.input.pipe.request('thread-follower-load-complete-history', { conversationId: threadId }, 30_000, before.owner);
                before = await this.snapshot(threadId, true, false);
            }
            const target = [...conversationTurns(before.state)].find(turn => turn.turnId === turnId);
            if (!target?.params?.input?.some((item) => item.type === 'text'))
                throw new Error('message_edit_unavailable');
            try {
                const reply = await this.input.pipe.request('thread-follower-edit-last-user-turn', {
                    conversationId: threadId, turnId, message, allowEarlierMessages: true,
                    shouldSendPermissionOverrides: false,
                }, 30_000, before.owner);
                if (reply.result?.ok !== true)
                    throw new Error('message_edit_unconfirmed');
            }
            catch {
                throw new Error('message_edit_unconfirmed');
            }
            return { threadId, delivery: 'desktop' };
        }
        finally {
            this.editing.delete(threadId);
        }
    }
    async modelConfig(threadId, catalog) {
        // Model settings are a small native response. A long thread's full state
        // can exceed the stream frame limit without making these settings invalid.
        // Reading a Web header must never navigate Desktop to a cold conversation.
        const [owner, models] = await Promise.all([
            measureOperation('model.owner', () => this.input.owner(threadId, false, 2000)), catalog,
        ]);
        if (typeof owner.settings.model !== 'string' || !owner.settings.model)
            throw new Error('desktop_model_unavailable');
        // Header reads must not subscribe to or wait for the complete conversation.
        // The existing approval/status poll supplies full settings independently.
        const state = this.input.state.peek(threadId, owner.id);
        const summary = state ? desktopSummary(state, owner.id) : null;
        const reasoningEffort = owner.settings.reasoningEffort
            ?? (summary && summary.model === owner.settings.model ? summary.reasoningEffort : '');
        const current = summary && summary.model === owner.settings.model
            && summary.reasoningEffort === reasoningEffort;
        const serviceTier = current ? summary.serviceTier : null;
        const tier = models.find(m => m.model === owner.settings.model)?.serviceTiers?.find((t) => t.id === serviceTier);
        return { model: owner.settings.model, reasoningEffort, serviceTier,
            fastMode: Boolean(serviceTier && /fast|priority/i.test(`${serviceTier} ${tier?.name || ''}`)),
            source: 'desktop', readOnly: !current || !models.length, models };
    }
    async updateModel(threadId, value, models) {
        const model = models.find(m => m.model === value.model);
        if (!model)
            throw new Error('model_not_available');
        if (!model.supportedReasoningEfforts.some((r) => r.reasoningEffort === value.reasoningEffort))
            throw new Error('reasoning_effort_not_available');
        const tier = value.fastMode === true ? model.serviceTiers.find((t) => /fast|priority/i.test(`${t.id} ${t.name}`))
            : model.serviceTiers.find((t) => t.id === model.defaultServiceTier) || model.serviceTiers.find((t) => /default|standard/i.test(`${t.id} ${t.name}`)) || { id: 'default' };
        if (!tier)
            throw new Error('fast_mode_not_available');
        const before = await this.snapshot(threadId, true, false);
        if (before.summary.status === 'active')
            throw new Error('model_config_turn_active');
        try {
            const result = await this.input.pipe.request('thread-follower-update-thread-settings', {
                conversationId: threadId, threadSettings: { model: model.model, effort: value.reasoningEffort, serviceTier: tier.id },
                condition: { ifModelEquals: before.state.latestModel, ifEffortEquals: before.state.latestReasoningEffort },
            }, 15000, before.owner);
            if (result.result?.applied !== true)
                throw new Error('desktop_settings_changed');
        }
        catch (error) {
            if (error.message === 'desktop_settings_changed')
                throw error;
            throw mutationError(error);
        }
        await this.input.state.waitFor(threadId, before.owner, state => {
            const summary = desktopSummary(state, before.owner);
            return summary.model === model.model && summary.reasoningEffort === value.reasoningEffort && summary.serviceTier === tier.id;
        }).catch(() => { throw new Error('desktop_settings_unconfirmed'); });
        const after = await this.modelConfig(threadId, models);
        if (after.model !== model.model || after.reasoningEffort !== value.reasoningEffort || after.serviceTier !== tier.id)
            throw new Error('desktop_settings_changed');
        return after;
    }
    async stop(threadId, expectedTurnId) {
        const before = await this.snapshot(threadId, true, false);
        if (!before.summary.canStop)
            return { stopped: true, turnId: null, goalPaused: before.state.threadGoal?.status === 'paused' };
        // A goal can move to a new turn between the poll and click. Stop the goal
        // itself in that case, rather than rejecting each automatic continuation.
        if (before.state.threadGoal?.status !== 'active' && expectedTurnId && before.summary.turnId !== expectedTurnId)
            throw new Error('desktop_turn_changed');
        try {
            const reply = await this.input.pipe.request('thread-follower-interrupt-turn', {
                conversationId: threadId, mode: 'user-stop',
            }, 15000, before.owner);
            if (reply.result?.ok !== true || reply.result?.goalPauseError)
                throw new Error('desktop_stop_unconfirmed');
        }
        catch (error) {
            if (error.message === 'desktop_stop_unconfirmed')
                throw error;
            throw mutationError(error);
        }
        const after = await this.input.state.waitFor(threadId, before.owner, state => state.threadRuntimeStatus?.type !== 'active' && state.threadGoal?.status !== 'active').catch(() => { throw new Error('desktop_stop_unconfirmed'); });
        return { stopped: true, turnId: before.summary.turnId, goalPaused: after.threadGoal?.status === 'paused' };
    }
    async compact(threadId) {
        const before = await this.snapshot(threadId, true, true);
        if (before.summary.canStop || before.state.requests?.length || before.summary.status !== 'idle')
            throw new Error('desktop_command_busy');
        try {
            const reply = await this.input.pipe.request('thread-follower-compact-thread', { conversationId: threadId }, 30_000, before.owner);
            if (reply.result?.ok !== true)
                throw new Error('desktop_operation_unknown');
            return { threadId, started: true };
        }
        catch (error) {
            throw mutationError(error);
        }
    }
    async setCollaborationMode(threadId, mode) {
        if (mode !== 'plan' && mode !== 'default')
            throw new Error('collaboration_mode_invalid');
        const before = await this.snapshot(threadId, true, true);
        if (before.summary.canStop || before.state.requests?.length)
            throw new Error('desktop_command_busy');
        if (!before.summary.model)
            throw new Error('desktop_model_unavailable');
        try {
            const reply = await this.input.pipe.request('thread-follower-update-thread-settings', {
                conversationId: threadId, threadSettings: { collaborationMode: { mode, settings: {
                            model: before.summary.model, reasoning_effort: before.summary.reasoningEffort || null,
                            developer_instructions: null,
                        } } },
            }, 15000, before.owner);
            if (reply.result?.applied !== true)
                throw new Error('desktop_settings_changed');
        }
        catch (error) {
            throw mutationError(error);
        }
        await this.input.state.waitFor(threadId, before.owner, state => desktopSummary(state, before.owner).collaborationMode === mode)
            .catch(() => { throw new Error('desktop_settings_unconfirmed'); });
        return { threadId, mode };
    }
    async respondToQuestion(threadId, id, value) {
        const before = await this.snapshot(threadId, true, false);
        const pending = before.summary.userInputRequests.find(r => r.id === id);
        const request = (before.state.requests || []).find((r) => approvalId(before.owner, r) === id);
        if (!pending || !request)
            throw new Error('desktop_question_expired');
        const answers = userInputAnswers(pending.questions, value);
        try {
            const reply = await this.input.pipe.request('thread-follower-submit-user-input', {
                conversationId: threadId, requestId: request.id, response: { answers },
            }, 15000, before.owner);
            if (reply.result?.ok !== true)
                throw new Error('desktop_question_unconfirmed');
        }
        catch (error) {
            if (error.message === 'desktop_question_unconfirmed')
                throw error;
            throw mutationError(error);
        }
        await this.input.state.waitFor(threadId, before.owner, state => !(state.requests || []).some((r) => approvalId(before.owner, r) === id)).catch(() => { throw new Error('desktop_question_unconfirmed'); });
        return { id, resolved: true };
    }
    async respond(threadId, id, approved) {
        const before = await this.snapshot(threadId, true, false);
        const request = (before.state.requests || []).find((r) => approvalId(before.owner, r) === id);
        if (!request || !Object.hasOwn(approvalMethods, request.method))
            throw new Error('desktop_approval_expired');
        if (!before.summary.approvals.find((r) => r.approvalId === id)?.actionable)
            throw new Error('desktop_approval_unsupported');
        const method = approvalMethods[request.method];
        const params = { conversationId: threadId, requestId: request.id };
        if (method === 'thread-follower-permissions-request-approval-response') {
            if (approved && (!request.params?.permissions || typeof request.params.permissions !== 'object'))
                throw new Error('desktop_approval_unsupported');
            params.response = { permissions: approved ? request.params.permissions : {}, scope: 'turn' };
        }
        else {
            const decisions = request.params?.availableDecisions;
            params.decision = approved ? 'accept' : Array.isArray(decisions) && decisions.includes('cancel') ? 'cancel' : 'decline';
            if (Array.isArray(decisions) && !decisions.includes(params.decision))
                throw new Error('desktop_approval_unsupported');
        }
        try {
            const reply = await this.input.pipe.request(method, params, 15000, before.owner);
            if (reply.result?.ok !== true)
                throw new Error('desktop_approval_unconfirmed');
        }
        catch (error) {
            if (error.message === 'desktop_approval_unconfirmed')
                throw error;
            throw mutationError(error);
        }
        await this.input.state.waitFor(threadId, before.owner, state => !(state.requests || []).some((r) => approvalId(before.owner, r) === id)).catch(() => { throw new Error('desktop_approval_unconfirmed'); });
        return { approvalId: id, approved, resolved: true };
    }
}
