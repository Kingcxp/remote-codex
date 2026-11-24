export const PERMISSION_MODES = ['ask', 'auto', 'full'];
export function normalizePermissionMode(value) {
    return PERMISSION_MODES.includes(value) ? value : 'ask';
}
