import { editIdentifier, editText } from './message-edit.js';
import { publicError } from '../shared/protocol.js';
import { measureOperation, operationMetrics } from './operation-metrics.js';
import { mergeDesktopHistoryPage } from './desktop-history.js';
import { SESSION_STATUS_MAX_AGE_MS } from '../shared/session-status.js';
import { mergeDesktopSessionStatuses, } from './codex-desktop.js';
const DESKTOP_STATUS_REFRESH_MS = 6_000;
const MEASURED_ACTIONS = new Set(['sessions.list', 'session.model-config.read', 'session.turns.list',
    'approval.pending', 'connector.status', 'session.permissions.read', 'turn.start']);
async function headerModelCatalog(codex) {
    let timer;
    try {
        return await Promise.race([
            measureOperation('model.catalog', () => codex.listModels({ allowStale: true })),
            new Promise(resolve => { timer = setTimeout(() => resolve([]), 1500); }),
        ]);
    }
    catch {
        return [];
    }
    finally {
        clearTimeout(timer);
    }
}
export function createRequestHandler({ codex, desktop, attachments, fileUploads, visualizations, downloads, deviceId, browser, messageQueue, deviceLabel = deviceId, mode = desktop ? 'desktop' : 'headless', networkAccess = false, allowFullAccess = false, onSessionStatuses, }) {
    let desktopStatusCache = null;
    let desktopStatusRefresh = null;
    let lastRefreshStarted = -Infinity;
    let revision = 0;
    const getDesktopStatuses = () => (desktopStatusCache && Date.now() - desktopStatusCache.updatedAt <= SESSION_STATUS_MAX_AGE_MS
        ? { revision: desktopStatusCache.revision, threads: desktopStatusCache.threads } : null);
    const refreshDesktopThreads = (callerThreadId) => {
        const caller = String(callerThreadId || '').trim();
        if (mode !== 'desktop' || !desktop || !caller || desktopStatusRefresh
            || Date.now() - lastRefreshStarted < DESKTOP_STATUS_REFRESH_MS)
            return;
        lastRefreshStarted = Date.now();
        desktopStatusRefresh = desktop.listThreads({ callerThreadId: caller, limit: 50 })
            .then((threads) => {
            const rows = (Array.isArray(threads) ? threads : []).slice().sort((a, b) => a.id.localeCompare(b.id));
            const changed = !desktopStatusCache || Date.now() - desktopStatusCache.updatedAt > SESSION_STATUS_MAX_AGE_MS
                || JSON.stringify(rows) !== JSON.stringify(desktopStatusCache.threads);
            desktopStatusCache = { threads: rows, updatedAt: Date.now(), revision: ++revision };
            if (changed)
                onSessionStatuses?.({ revision, threads: rows });
        })
            .catch(() => { })
            .finally(() => { desktopStatusRefresh = null; });
    };
    return async function handleRequest(message) {
        const { action, payload = {}, requestId, clientId, clientDeviceId, } = message;
        try {
            const run = () => dispatchAction({
                action, payload, requestId, clientId, clientDeviceId,
                codex, desktop, attachments, fileUploads, visualizations, downloads, deviceId, deviceLabel, mode, browser, messageQueue,
                networkAccess, allowFullAccess, getDesktopStatuses, refreshDesktopThreads,
            });
            const operation = () => ['session.compact', 'session.plan', 'session.pin', 'session.move', 'turn.stop'].includes(action)
                && messageQueue?.runOperation && requestId && (clientDeviceId || clientId)
                ? messageQueue.runOperation(String(clientDeviceId || clientId), requestId, { action, payload }, run) : run();
            const data = await (MEASURED_ACTIONS.has(action) ? measureOperation(action, operation) : operation());
            return { type: 'response', clientId, requestId, ok: true, data };
        }
        catch (error) {
            return { type: 'response', clientId, requestId, ok: false, error: publicError(error) };
        }
    };
}
async function dispatchAction({ action, payload, requestId, clientId, clientDeviceId, codex, desktop, attachments, fileUploads, visualizations, downloads, deviceId, deviceLabel, mode, browser, messageQueue, networkAccess, allowFullAccess, getDesktopStatuses, refreshDesktopThreads, }) {
    if (action === 'connector.diagnostics')
        return { operations: operationMetrics() };
    if (['queue.list', 'queue.remove', 'queue.steer', 'queue.pause'].includes(action)) {
        if (!messageQueue)
            throw new Error('message_queue_unavailable');
        const threadId = String(payload.threadId || '').trim();
        if (!threadId)
            throw new Error('thread_id_required');
        if (action === 'queue.steer') {
            if (!messageQueue.steer)
                throw new Error('message_queue_steer_unavailable');
            return messageQueue.steer(threadId, String(payload.id || ''));
        }
        if (action === 'queue.pause') {
            if (!messageQueue.setPaused || typeof payload.paused !== 'boolean')
                throw new Error('message_queue_invalid');
            return messageQueue.setPaused(threadId, payload.paused);
        }
        if (action === 'queue.list') {
            const [queue, desktopQueue] = await Promise.all([
                messageQueue.list(threadId),
                mode === 'desktop' && desktop?.controls?.readQueue
                    ? desktop.controls.readQueue(threadId).catch(() => ({ entries: [], available: false })) : undefined,
            ]);
            return { ...queue, ...(desktopQueue ? { desktopQueue } : {}) };
        }
        return messageQueue.remove(threadId, String(payload.id || ''));
    }
    if (action.startsWith('browser.')) {
        if (!browser)
            throw new Error('browser_control_not_enabled_on_connector');
        if (!clientId || !clientDeviceId)
            throw new Error('browser_authenticated_device_required');
        const client = { clientId, clientDeviceId };
        if (action === 'browser.bind') {
            // Validate the existing Session. Never create, resume, or send a prompt here.
            return browser.validateAndBind(client, payload.threadId, payload.target, (threadId) => codex.readSession(threadId), {
                replaceExisting: payload.replaceExisting === true, recoverOnly: payload.recoverOnly === true,
            });
        }
        if (action === 'browser.status')
            return browser.status(payload.threadId);
        if (action === 'browser.adopt')
            return browser.adopt(client, payload.operationRequestId, payload.parentGrantId, payload.target);
        if (action === 'browser.restore')
            return browser.restore(client, payload.grantId, payload.target);
        if (action === 'browser.navigate')
            return browser.navigate(client, payload.grantId, payload.target);
        if (action === 'browser.heartbeat')
            return browser.heartbeat(client, payload.grantId);
        if (action === 'browser.revoke')
            return browser.revoke(client, payload.grantId);
        if (action === 'browser.result')
            return browser.result(client, payload);
        throw new Error('browser_unknown_action');
    }
    if (action === 'connector.status') {
        const desktopState = mode === 'desktop' ? await desktop?.getCapabilities?.() : undefined;
        const supports = (...tools) => desktopState?.available === true && tools.every(tool => desktopState.tools.includes(tool));
        return {
            deviceId,
            deviceLabel,
            mode,
            platform: process.platform,
            codexOnline: Boolean(codex.child),
            ...(mode === 'desktop' ? { desktopOnline: desktopState?.available === true, desktopTools: desktopState?.tools || [], desktopInputOnline: desktopState?.inputAvailable === true } : {}),
            activeTurn: codex.activeTurns.size > 0,
            capabilities: { sessionDelete: mode === 'headless', networkAccess, fullAccess: allowFullAccess,
                ...(codex.listMessages ? { messageHistory: true } : {}), ...(codex.searchMessages ? { messageSearch: true } : {}),
                ...(mode === 'desktop' && desktop?.workspaceLibrary && supports('list_projects', 'list_threads') ? { workspaceManagement: true } : {}),
                ...(mode === 'desktop' && desktop?.controls?.compact && desktop?.controls?.setCollaborationMode && desktopState?.inputAvailable ? { desktopCommands: true } : {}),
                ...(messageQueue ? { messageQueue: true } : {}),
                ...(mode === 'desktop' && desktop?.controls && desktopState?.inputAvailable ? { desktopNativeState: true, desktopNativeImages: Boolean(attachments.nativeInput) } : {}),
                ...(mode === 'desktop' && desktop?.archiveThread && supports('read_thread', 'set_thread_archived') ? { sessionArchive: true, sessionArchivePendingApproval: true } : {}),
                ...(mode === 'desktop' && desktop?.restoreThread && supports('set_thread_archived') ? { sessionRestore: true } : {}),
                ...(fileUploads ? { fileUpload: true } : {}), ...(browser ? { browserControl: true, browserGrantReplacement: true } : {}) },
        };
    }
    if (action === 'sessions.list') {
        const sessions = await codex.listSessions({ cwd: payload.cwd });
        const desktopStatuses = getDesktopStatuses();
        refreshDesktopThreads(sessions[0]?.id);
        return {
            sessions: mergeDesktopSessionStatuses(sessions, desktopStatuses?.threads || [], [...codex.activeTurns.values()].map(turn => turn.threadId)),
            desktopStatuses,
        };
    }
    if (action === 'session.read')
        return codex.readSession(String(payload.threadId || ''));
    if (action === 'session.messages.list') {
        if (!codex.listMessages)
            throw new Error('session_history_unavailable');
        return codex.listMessages(String(payload.threadId || ''), payload);
    }
    if (action === 'messages.search') {
        if (!codex.searchMessages)
            throw new Error('session_history_unavailable');
        return codex.searchMessages(payload);
    }
    if (action === 'workspace.library') {
        if (!desktop?.workspaceLibrary)
            throw new Error('desktop_library_unavailable');
        return desktop.workspaceLibrary(String(payload.threadId || ''));
    }
    if (action === 'session.pin' || action === 'session.move') {
        if (!desktop?.manageThread)
            throw new Error('desktop_library_unavailable');
        if (action === 'session.pin' && typeof payload.pinned !== 'boolean')
            throw new Error('desktop_library_update_failed');
        return desktop.manageThread(String(payload.threadId || ''), action === 'session.pin' ? 'pin' : 'move', action === 'session.pin' ? payload.pinned : payload.projectId);
    }
    if (action === 'session.compact' || action === 'session.plan') {
        const threadId = String(payload.threadId || '').trim();
        if (!threadId)
            throw new Error('thread_id_required');
        if (mode !== 'desktop' || !desktop?.controls?.compact || !desktop.controls.setCollaborationMode)
            throw new Error('desktop_command_unsupported');
        await codex.prepareDesktopTurn?.();
        // Prevent an automatic queue delivery from racing a settings/compaction operation.
        const wasPaused = Boolean(messageQueue?.list(threadId)?.paused);
        const release = await messageQueue?.hold?.(threadId);
        if (!release)
            await messageQueue?.setPaused?.(threadId, true);
        try {
            return action === 'session.compact' ? await desktop.controls.compact(threadId)
                : await desktop.controls.setCollaborationMode(threadId, payload.mode);
        }
        finally {
            if (release)
                release();
            else if (!wasPaused)
                await messageQueue?.setPaused?.(threadId, false);
        }
    }
    if (action === 'session.archive') {
        if (mode !== 'desktop' || !desktop?.archiveThread)
            throw new Error('session_archive_unsupported');
        if (payload.confirm !== true)
            throw new Error('session_archive_confirmation_required');
        const threadId = String(payload.threadId || '').trim();
        if (!threadId)
            throw new Error('thread_id_required');
        if (messageQueue?.list(threadId).entries.length)
            throw new Error('message_queue_pending');
        if (codex.getActiveTurn(threadId)) {
            throw new Error('session_archive_not_idle');
        }
        const result = await desktop.archiveThread({ threadId, cancelPendingApproval: payload.cancelPendingApproval === true });
        if (result.threadId !== threadId || result.archived !== true)
            throw new Error('session_delivery_mismatch');
        browser?.clearSession(threadId);
        return result;
    }
    if (action === 'session.restore') {
        if (mode !== 'desktop' || !desktop?.restoreThread)
            throw new Error('session_restore_unsupported');
        const threadId = String(payload.threadId || '').trim();
        if (!threadId)
            throw new Error('thread_id_required');
        const result = await desktop.restoreThread({ threadId });
        if (result.threadId !== threadId || result.archived !== false)
            throw new Error('session_delivery_mismatch');
        return result;
    }
    if (action === 'session.delete') {
        if (mode !== 'headless')
            throw new Error('session_delete_headless_only');
        if (payload.confirm !== true)
            throw new Error('session_delete_confirmation_required');
        const result = await codex.deleteSession(payload.threadId);
        browser?.clearSession(result.threadId);
        return result;
    }
    if (action === 'session.rename') {
        const threadId = String(payload.threadId || '');
        if (mode === 'desktop') {
            if (!desktop)
                throw new Error('desktop_app_unavailable');
            return desktop.renameThread({
                threadId,
                name: payload.name,
            });
        }
        return codex.renameSession(threadId, payload.name);
    }
    if (action === 'session.turns.list') {
        const threadId = String(payload.threadId || '');
        const page = codex.listSessionTurns(threadId, {
            cursor: payload.cursor,
            limit: payload.limit,
            mode: payload.mode,
            questionIds: payload.questionIds,
        });
        if (mode !== 'desktop' || payload.cursor || !desktop?.controls?.readHistory)
            return page;
        // Disk writes can lag an entire compaction. The owner has the accepted input,
        // compaction lifecycle and streamed summaries before they are persisted.
        const [history, native] = await Promise.allSettled([page, desktop.controls.readHistory(threadId)]);
        if (history.status === 'rejected')
            throw history.reason;
        return mergeDesktopHistoryPage(history.value, native.status === 'fulfilled' ? native.value : null);
    }
    if (action === 'session.turn.diff.read') {
        return codex.readTurnDiff(String(payload.threadId || ''), String(payload.turnId || ''));
    }
    if (action === 'session.model-config.read') {
        if (mode === 'desktop') {
            if (!desktop?.controls || !codex.listModels)
                throw new Error('desktop_input_unsupported');
            const threadId = String(payload.threadId || '');
            const catalog = headerModelCatalog(codex);
            try {
                return await desktop.controls.modelConfig(threadId, catalog);
            }
            catch (error) {
                if (!codex.readStoredModelConfig)
                    throw error;
                return measureOperation('model.persisted', () => codex.readStoredModelConfig(threadId, catalog));
            }
        }
        return codex.readModelConfig(String(payload.threadId || ''));
    }
    if (action === 'session.model-config.update') {
        if (mode === 'desktop') {
            if (!desktop?.controls || !codex.listModels)
                throw new Error('desktop_input_unsupported');
            return desktop.controls.updateModel(String(payload.threadId || ''), payload, await codex.listModels());
        }
        return codex.updateModelConfig(String(payload.threadId || ''), payload);
    }
    if (action === 'session.permissions.read') {
        if (mode === 'desktop' && desktop?.controls?.permissions) {
            const threadId = String(payload.threadId || '');
            try {
                return await desktop.controls.permissions(threadId, { networkAccess: Boolean(networkAccess), allowFullAccess: Boolean(allowFullAccess) });
            }
            catch (error) {
                if (error.message !== 'desktop_input_not_ready' || !codex.readStoredPermissionConfig)
                    throw error;
                return { ...await codex.readStoredPermissionConfig(threadId), allowFullAccess: Boolean(allowFullAccess) };
            }
        }
        const desktopState = mode === 'desktop' ? await desktop?.getCapabilities?.() : undefined;
        return {
            ...await codex.readPermissionMode(String(payload.threadId || ''), { fresh: mode === 'desktop' }),
            editable: mode === 'headless',
            networkAccess,
            allowFullAccess,
            ...(mode === 'desktop' && desktop?.openThread && desktopState?.available && desktopState.tools.includes('navigate_to_codex_page') ? { canOpenOnDesktop: true } : {}),
        };
    }
    if (action === 'session.desktop.open') {
        if (mode !== 'desktop' || !desktop?.openThread)
            throw new Error('desktop_app_unavailable');
        return desktop.openThread({ threadId: payload.threadId });
    }
    if (action === 'session.permissions.update') {
        if (mode === 'desktop' && desktop?.controls?.updatePermissions) {
            const threadId = String(payload.threadId || '').trim();
            try {
                return await desktop.controls.updatePermissions(threadId, payload, { networkAccess: Boolean(networkAccess), allowFullAccess: Boolean(allowFullAccess) });
            }
            catch (error) {
                // Only a pre-mutation owner lookup failure can use the cold path.
                if (error.message !== 'desktop_input_not_ready' || !codex.updateStoredPermissionConfig)
                    throw error;
                return { ...await codex.updateStoredPermissionConfig(threadId, payload), allowFullAccess: Boolean(allowFullAccess) };
            }
        }
        if (mode !== 'headless')
            throw new Error('desktop_permission_mode_managed_on_computer');
        return {
            ...await codex.updatePermissionMode(String(payload.threadId || ''), payload.mode),
            editable: true,
            networkAccess,
            allowFullAccess,
        };
    }
    if (action === 'attachment.upload')
        return attachments.save(payload);
    if (action.startsWith('file.upload.')) {
        if (!fileUploads)
            throw new Error('file_upload_unsupported');
        const owner = clientDeviceId || clientId || '';
        if (action === 'file.upload.begin')
            return fileUploads.begin(payload, owner);
        if (action === 'file.upload.chunk')
            return fileUploads.chunk(payload, owner);
        if (action === 'file.upload.complete')
            return fileUploads.complete(payload, owner);
        if (action === 'file.upload.cancel')
            return fileUploads.cancel(payload, owner);
        throw new Error('unsupported_action');
    }
    if (action === 'attachment.read')
        return attachments.read(payload);
    if (action === 'visualization.read')
        return visualizations.read(payload);
    const downloadOwner = clientDeviceId || clientId;
    if (action === 'file.download.open')
        return downloads.open(payload, downloadOwner);
    if (action === 'file.download.chunk')
        return downloads.read(payload, downloadOwner);
    if (action === 'file.download.close')
        return downloads.close(payload, downloadOwner);
    if (action === 'file.markdown.read')
        return downloads.readMarkdown(payload);
    if (action === 'file.text.read')
        return downloads.readText(payload);
    if (action === 'turn.edit.prepare' || action === 'turn.edit') {
        if (!codex.prepareMessageEdit)
            throw new Error('message_edit_unavailable');
        const threadId = editIdentifier(payload.threadId), turnId = editIdentifier(payload.turnId);
        if (codex.getActiveTurn(threadId))
            throw new Error('message_edit_busy');
        if (action === 'turn.edit.prepare') {
            const { input: _input, ...plan } = await codex.prepareMessageEdit(threadId, turnId);
            return plan;
        }
        if (payload.confirm !== true || typeof payload.token !== 'string')
            throw new Error('message_edit_invalid');
        const text = editText(payload.text);
        if (mode === 'headless')
            return { ...await codex.startTurn({
                    threadId, text, clientId, requestId, edit: { turnId, token: payload.token, confirm: true },
                }), delivery: 'appServer' };
        if (!desktop?.controls?.editMessage)
            throw new Error('message_edit_unavailable');
        const plan = await codex.prepareMessageEdit(threadId, turnId);
        if (plan.token !== payload.token)
            throw new Error('message_edit_changed');
        await codex.prepareDesktopTurn?.();
        try {
            return await desktop.controls.editMessage(threadId, turnId, text);
        }
        catch (error) {
            // Only missing ownership before the native mutation permits the cold
            // runtime. Core's writer lock protects a simultaneous Desktop takeover.
            if (error.message !== 'desktop_input_not_ready')
                throw error;
            return { ...await codex.startTurn({ threadId, text, clientId, requestId,
                    edit: { turnId, token: payload.token, confirm: true } }), delivery: 'appServer' };
        }
    }
    if (action === 'turn.start') {
        const { edit: _edit, ...input } = payload;
        return startTurn({ codex, desktop, mode, payload: input, clientId, clientDeviceId, requestId, browser, attachments, messageQueue });
    }
    if (action === 'turn.steer') {
        return {
            ...await sendWithBrowserContext(browser, String(payload.threadId || '').trim(), payload.text, (text) => codex.steerTurn({ ...payload, text, clientId, requestId })),
            delivery: 'appServer',
        };
    }
    if (action === 'session.desktop.state') {
        if (mode !== 'desktop' || !desktop?.controls)
            throw new Error('desktop_input_unsupported');
        return desktop.controls.read(String(payload.threadId || ''));
    }
    if (action === 'turn.stop') {
        const targetThreadId = String(payload.threadId || '').trim();
        if (!targetThreadId)
            throw new Error('thread_id_required');
        const release = await messageQueue?.hold?.(targetThreadId);
        try {
            await messageQueue?.setPaused?.(targetThreadId, true);
            if (payload.source === 'desktop') {
                if (mode !== 'desktop' || !desktop?.controls)
                    throw new Error('desktop_input_unsupported');
                return await desktop.controls.stop(targetThreadId, payload.expectedTurnId);
            }
            return await codex.stopTurn(targetThreadId);
        }
        finally {
            release?.();
        }
    }
    if (action === 'approval.pending') {
        const pending = await codex.listApprovals(payload.threadId, clientId);
        if (pending.approvals?.length || pending.activeTurn)
            return pending;
        const threadId = String(payload.threadId || '').trim();
        if (!threadId)
            return pending;
        if (mode !== 'desktop' || !desktop)
            return pending;
        try {
            if (desktop.controls) {
                const state = await desktop.controls.read(threadId);
                return { ...pending, approvals: state.approvals, desktopState: state,
                    ...(state.waitingOnApproval && !state.approvals.length && !state.userInputRequests?.length ? { externalApproval: {
                            approvalId: '', threadId, kind: 'desktop', source: 'desktop', actionable: false,
                        } } : {}) };
            }
            const state = await desktop.readThreadState({
                threadId,
            });
            if (state.waitingOnApproval) {
                return {
                    ...pending,
                    desktopState: state,
                    externalApproval: {
                        approvalId: '',
                        threadId,
                        kind: 'desktop',
                        summary: 'This approval is owned by Codex Desktop.',
                        actionable: false,
                    },
                };
            }
            return { ...pending, desktopState: state };
        }
        catch (error) {
            // Unknown is not approval resolution. Keep the last state and retry.
            return { ...pending, desktopStatusUnavailable: true, desktopStatusError: publicError(error) };
        }
    }
    if (action === 'user-input.respond') {
        const threadId = String(payload.threadId || '').trim();
        if (!threadId)
            throw new Error('thread_id_required');
        if (mode !== 'desktop' || !desktop?.controls?.respondToQuestion)
            throw new Error('desktop_input_unsupported');
        return desktop.controls.respondToQuestion(threadId, String(payload.id || ''), payload.answers);
    }
    if (action === 'approval.respond') {
        if (String(payload.approvalId || '').startsWith('desktop:')) {
            if (mode !== 'desktop' || !desktop?.controls)
                throw new Error('desktop_input_unsupported');
            if (typeof payload.approved !== 'boolean')
                throw new Error('approval_decision_required');
            return desktop.controls.respond(String(payload.threadId || ''), payload.approvalId, payload.approved);
        }
        return codex.respondApproval(payload.approvalId, payload.approved === true, payload.threadId);
    }
    throw new Error('unsupported_action');
}
async function startTurn({ codex, desktop, mode, payload, clientId, clientDeviceId, requestId, browser, attachments, messageQueue, }) {
    const threadId = String(payload.threadId || '').trim();
    if (threadId && messageQueue && payload.deliveryMode !== 'steer') {
        const imagePath = payload.image && attachments.nativeInput ? await attachments.nativeInput(payload.image) : undefined;
        if (payload.image && !imagePath)
            throw new Error('desktop_image_unsupported');
        return sendWithBrowserContext(browser, threadId, payload.text, async (text) => messageQueue.enqueue({
            threadId, text: String(text || ''), requestId: String(requestId || ''), ...(imagePath ? { imagePath } : {}),
        }, String(clientDeviceId || clientId || '')));
    }
    if (!threadId || mode === 'headless') {
        // A reloaded/reconnected browser may have missed turn.started. Resolve
        // delivery from the connector's ownership, never from browser hints.
        const active = threadId ? codex.getActiveTurn(threadId) : null;
        const steer = threadId && active?.threadId === threadId
            && active.state === 'running' && active.turnId;
        return { ...await sendWithBrowserContext(browser, threadId, payload.text, (text) => steer
                ? codex.steerTurn({ ...payload, text, clientId, requestId })
                : codex.startTurn({ ...payload, text, clientId, requestId })), delivery: 'appServer' };
    }
    // Existing Desktop tasks must keep their original writer. Starting or
    // resuming them through the bridge's app-server creates a second writer and
    // makes later Desktop delivery fail with "already has an active writer".
    if (!desktop)
        throw new Error('desktop_app_unavailable');
    const imagePath = payload.image && attachments.nativeInput ? await attachments.nativeInput(payload.image) : undefined;
    if (payload.image && !imagePath)
        throw new Error('desktop_image_unsupported');
    await codex.prepareDesktopTurn?.();
    return sendWithBrowserContext(browser, threadId, payload.text, (text) => desktop.sendMessage({
        threadId,
        text,
        requestId,
        ...(imagePath ? { imagePath } : {}),
    }));
}
function sendWithBrowserContext(browser, threadId, text, deliver) {
    return browser ? browser.withContext(threadId, text, deliver) : deliver(text);
}
