const samples = [];
const pending = new Set();
export function operationMetrics() {
    return [...samples.map(sample => ({ ...sample })), ...[...pending].map(sample => ({
            ...sample, elapsedMs: Math.max(0, Date.now() - sample.startedAt),
        }))];
}
export async function measureOperation(operation, run) {
    const startedAt = Date.now(), start = performance.now();
    const active = { operation, startedAt, elapsedMs: 0, outcome: 'pending' };
    if (pending.size < 32)
        pending.add(active);
    let outcome = 'ok';
    try {
        return await run();
    }
    catch (error) {
        const message = error instanceof Error ? error.message : '';
        outcome = /timeout/i.test(message) ? 'timeout' : /frame size|too_large/i.test(message) ? 'oversized'
            : /no-client|not_ready/i.test(message) ? 'not_ready' : /unsupported|version-mismatch/i.test(message) ? 'unsupported'
                : /unavailable|closed|disconnect/i.test(message) ? 'unavailable' : 'error';
        throw error;
    }
    finally {
        pending.delete(active);
        samples.push({ operation, startedAt, elapsedMs: Math.round(performance.now() - start), outcome });
        if (samples.length > 128)
            samples.shift();
    }
}
