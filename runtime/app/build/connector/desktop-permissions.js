import { createHash } from 'node:crypto';
import { PERMISSION_MODES } from '../shared/permission-mode.js';
import { permissionSettings } from './app-server-permissions.js';
export function desktopPermissionConfig(state, capabilities) {
    const settings = state.latestThreadSettings;
    if (!settings?.sandboxPolicy || settings.approvalPolicy == null)
        throw new Error('desktop_permissions_unavailable');
    const { sandboxPolicy: sandbox, approvalPolicy, approvalsReviewer, activePermissionProfile } = settings;
    const profile = activePermissionProfile?.id;
    const builtin = !profile || [':workspace', ':danger-full-access', ':read-only'].includes(profile);
    let mode = 'custom';
    if (builtin && sandbox.type === 'dangerFullAccess' && approvalPolicy === 'never'
        && approvalsReviewer === 'user')
        mode = 'full';
    if (builtin && sandbox.type === 'workspaceWrite' && approvalPolicy === 'on-request') {
        if (approvalsReviewer === 'user')
            mode = 'ask';
        if (approvalsReviewer === 'auto_review')
            mode = 'auto';
    }
    // Guard the permission selection, not Desktop-managed workspace roots: those
    // are normalized asynchronously and are not editable through this control.
    const settingsToken = createHash('sha256').update(JSON.stringify({ sandbox: {
            type: sandbox.type, networkAccess: sandbox.networkAccess,
            excludeTmpdirEnvVar: sandbox.excludeTmpdirEnvVar, excludeSlashTmp: sandbox.excludeSlashTmp,
        }, approvalPolicy, approvalsReviewer, profile: builtin ? null : activePermissionProfile, cwd: state.cwd })).digest('hex');
    return { mode, settingsToken, source: 'desktop', editable: true, ...capabilities };
}
export function desktopPermissionSettings(mode, state, capabilities) {
    if (!PERMISSION_MODES.includes(mode))
        throw new Error('permission_mode_invalid');
    if (mode === 'full' && !capabilities.allowFullAccess)
        throw new Error('full_access_not_allowed');
    if (typeof state.cwd !== 'string' || !state.cwd.trim())
        throw new Error('desktop_permissions_unavailable');
    // Desktop clears the previous named profile when a sandboxPolicy is supplied.
    // No model, provider, cwd, global config or unrelated settings are overwritten.
    return permissionSettings(mode, state.cwd, capabilities.networkAccess).turn;
}
