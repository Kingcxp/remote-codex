import { randomUUID, timingSafeEqual } from 'node:crypto';
import { BRIDGE_PROTOCOL_VERSION } from './protocol-contract.js';
export const MAX_FRAME_BYTES = 8 * 1024 * 1024;
export function createId(prefix) {
    return `${prefix}-${randomUUID()}`;
}
export function parseFrame(data) {
    const text = Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
    if (Buffer.byteLength(text) > MAX_FRAME_BYTES)
        throw new Error('frame_too_large');
    const value = JSON.parse(text);
    if (!value || typeof value !== 'object' || Array.isArray(value))
        throw new Error('invalid_frame');
    return value;
}
export function safeSend(socket, payload) {
    if (!socket || socket.readyState !== socket.OPEN)
        return false;
    try {
        socket.send(JSON.stringify({ ...payload, version: BRIDGE_PROTOCOL_VERSION }));
        return true;
    }
    catch {
        return false;
    }
}
export function secretMatches(actual, expected) {
    const left = Buffer.from(String(actual || ''), 'utf8');
    const right = Buffer.from(String(expected || ''), 'utf8');
    return left.length === right.length && left.length > 0 && timingSafeEqual(left, right);
}
export function publicError(error) {
    const message = String(error instanceof Error ? error.message : error || 'unknown_error');
    if (/token|secret|password|credential/i.test(message))
        return 'authentication_failed';
    return message.slice(0, 500);
}
export function normalizeBridgeUrl(value) {
    let url;
    try {
        url = new URL(String(value || '').trim());
    }
    catch {
        throw new Error('bridge_url_invalid');
    }
    if (url.protocol !== 'ws:' && url.protocol !== 'wss:')
        throw new Error('bridge_url_invalid');
    if (url.username || url.password || url.search || url.hash)
        throw new Error('bridge_url_invalid');
    return url.href;
}
