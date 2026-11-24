export const BROWSER_LINK_REQUEST = 'anywhere.sidepanel.link.request';
export const BROWSER_LINK_RESPONSE = 'anywhere.sidepanel.link.response';
// A sponsor signs only this domain-separated, target-bound transcript. Its
// private key never leaves Web storage and the proof cannot authenticate Web.
export function browserLinkContext(extensionOrigin, device) {
    if (!/^chrome-extension:\/\/[a-p]{32}$/.test(extensionOrigin)
        || !device || !/^[a-f0-9]{64}$/.test(device.id) || !/^[a-f0-9]{64}$/.test(device.publicKey)) {
        throw new Error('invalid_browser_link');
    }
    return ['codex-anywhere-browser-link-v1', extensionOrigin, device.id, device.publicKey].join('\n');
}
export function parseBrowserLinkRequest(value) {
    if (!value || typeof value !== 'object')
        return null;
    const v = value;
    if (!/^[a-f0-9-]{32,36}$/.test(v.requestId) || !/^[a-f0-9]{64}$/.test(v.challenge))
        return null;
    try {
        browserLinkContext(v.extensionOrigin, v.device);
    }
    catch {
        return null;
    }
    return { requestId: v.requestId, challenge: v.challenge, extensionOrigin: v.extensionOrigin,
        device: { id: v.device.id, publicKey: v.device.publicKey } };
}
